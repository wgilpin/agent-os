# Phase 0 — Research: Agent Runtime Kit

All spec "NEEDS CLARIFICATION" are pre-resolved by the bake-off (`.planning/bakeoff-agent-framework/SCORECARD.md`) and the spec's Assumptions. This file records the load-bearing decisions and the residual risks the tests must close.

## Decision 1 — Framework: `pydantic-ai-slim[openai]==2.5.0` (exact pin)

- **Decision**: Back the kit with `pydantic-ai-slim[openai]==2.5.0`, pinned exact. The `[openai]` extra is unavoidable — `OpenAIChatModel`/`OpenAIProvider` is the supported way to speak chat-completions JSON to a custom endpoint.
- **Rationale**: Bake-off proved first-class UDS transport, offline-total (0 egress), zero uncommanded calls, bounded/visible retries, and markedly more declarative bodies. Real costs (0.19 s import delta, ~37 MB image) are immaterial for container-run agents.
- **Alternatives considered**: No-framework ~200-line loop (kept in `.planning/` as the exit ramp / kit-swap fallback, not shipped); openai-agents SDK (not run — deprioritized). The kit is the seam behind which the framework could be swapped for a kit release cost, not a generation-contract change.
- **Version note**: latest on PyPI is 2.5.0 (verified with a cache-refreshed `uv` resolve); the earlier "2.9.0" claim was a bad web extraction and is wrong.

## Decision 2 — Transport: httpx UDS client into OpenAIProvider

- **Decision**: `substrate_model()` builds `httpx.AsyncClient(transport=httpx.AsyncHTTPTransport(uds=INFERENCE_SOCKET), base_url="http://localhost/v1")`, feeds it to `OpenAIProvider(base_url=…, api_key=RUN_TOKEN, http_client=…)`, and returns `OpenAIChatModel(AGENT_MODEL, provider=…)`.
- **Rationale**: This is the exact shape proven in `candidates/run_pydai.py` / the SCORECARD seed. `api_key=RUN_TOKEN` is the key move: the OpenAI client sends `Authorization: Bearer <api_key>`, so the run token lands in the header the broker authenticates on (FR-003) with **zero kit-side request rewriting** (httpx event hooks explicitly rejected by FR-003 unless a hard blocker appears — none did).
- **Env contract**: `INFERENCE_SOCKET`, `RUN_TOKEN`, `AGENT_MODEL` are already injected by `run_worker.ex`. The kit reads them; the body never does (FR-002). Missing/empty → fail fast (FR-009).
- **Alternatives considered**: Kit-side httpx event hook to inject auth — rejected by the spec. Passing run token in the JSON body (native shape) — rejected: the framework owns the request body and won't add a `run_token` field, and the Bearer mechanism is cleaner and is what OpenAI clients already do.

## Decision 3 — Broker surface: single-turn `/v1/chat/completions`, NOT a server-side loop

- **Decision**: Add a `POST /v1/chat/completions` route to the broker's UDS listener. It authenticates via `Authorization: Bearer <run_token>`, decodes the OpenAI request (`model`, `messages`, optional `tools`), performs **one** metered completion, and returns a standard OpenAI `chat.completion` JSON. It does **not** recurse or execute tools server-side.
- **Rationale**: pydantic-ai drives the tool loop **client-side** — it receives `tool_calls`, executes the body's plain functions locally, and posts the results back as the next `/v1/chat/completions` request. Each turn is one discrete metered broker request → spend reconciles call-for-call (FR-007, SC-003). Reusing the native path's `do_complete_loop` (which executes tools via `CapabilityRail` and recurses) would be wrong here: the golden task's tools are plain in-body functions, not manifest connectors.
- **Metering parity**: the new path reuses `InferencePrice.lookup/2`, the spend-window normalization (`SpendLedger.current_entry/3`), the pre-check (`spent >= cap → {:breach, :spend}`), `InferencePrice.micro_dollars/2`, the `{:put, agent_name, entry}` ledger write, and the post-meter breach check — **the identical helpers** the native path uses. Only the loop/tool-execution and the wire (de)serialization differ. This is what keeps the chokepoint semantics identical (US2) without moving the trust boundary.
- **Auth-header plumbing**: `read_http_request/2` currently extracts only the request path. It must also capture the `Authorization` header value and pass it to the route handler so the Bearer token can be resolved. The native path is unchanged (it still reads `run_token` from the body).
- **Response construction**: with a stubbed `provider_fn` (tests), the broker reconstructs the OpenAI envelope from the provider's `message` + token usage: `{"choices":[{"index":0,"message":…,"finish_reason":…}],"usage":{"prompt_tokens":…,"completion_tokens":…},"model":…}`. With the real provider (`real_provider_fn`), the upstream OpenRouter response is already OpenAI-shaped and can be passed through (only usage is needed for metering). Tests use the stub, so live upstream shape is not asserted (Constitution IV).
- **Unsupported features**: streaming and other OpenAI extras the broker doesn't implement are rejected cleanly (the kit does not enable streaming; a `stream: true` request is refused rather than silently half-supported) — edge case in spec §Edge Cases.

## Decision 4 — Retry budget: framework `retries=2`, no uncommanded calls

- **Decision**: The kit constructs `Agent(..., retries=2)` (kit-level constant, not per-agent config). No telemetry, background requests, implicit tool invocation, or direct-provider fallback is enabled.
- **Rationale**: Bake-off confirmed retries are explicit, bounded, and each is a discrete metered broker request; malformed-args fails closed after exactly the budget. Default 2 is the bake-off default and the spec default.

## Decision 5 — History threading (session-shaped from day one)

- **Decision**: `run_agent` accepts an optional `history` field in the stdin payload. It deserializes it into pydantic-ai's message-history type and passes it as `message_history=` to `run_sync`. After the run it appends the run's **new** messages (`result.new_messages()`) as the outcome record's `history` delta. The kit never persists — the substrate does (Phase 14).
- **Rationale**: Cheap now, expensive to retrofit; fixes the body contract before Stage-4 generation (13-03) targets it. A future chat-turn agent is the *same body* invoked with history.
- **Serialization**: pydantic-ai exposes `ModelMessagesTypeAdapter` (pydantic `TypeAdapter`) to dump/validate messages to/from JSON-safe Python objects. The substrate treats the blob as opaque-but-JSON. Malformed history → fail fast with a structured error outcome (FR-009, no silent truncation).
- **Outcome-record compatibility**: `AgentOS.OutcomeRecord.parse/1` requires `outcome` + `reason` strings and **tolerates extra keys** (it pattern-matches those two; a `history` key passes through untouched). So adding `history` is backward-compatible — no Elixir OutcomeRecord change is required, and existing agents (which emit no `history`) are unaffected.

## Decision 6 — Baking & offline proof

- **Decision**: Edit `agents/generated.Dockerfile` to (a) add `pydantic-ai-slim[openai]==2.5.0` to `pyproject.toml` so `uv sync --frozen` installs it into the image venv at **build** time, and (b) `COPY agent_os_runtime` into `/app` so `import agent_os_runtime` resolves on the baked `PYTHONPATH=/app`. No agent-provision-time pip/uv install.
- **Offline proof**: extend the spec-044 containment probe — `docker run --network=none` the sample agent with only the UDS mounted; assert golden-task success and zero egress. tiktoken sits in the tree but the bake-off flow never triggered its lazy download; `--network=none` makes any such fetch a hard failure, closing the residual risk the SCORECARD flagged.
- **Regression gate**: the Python kit suite (stub UDS broker + AF_UNIX-only jail) is documented as the mandatory gate for any future framework pin bump (FR-012, SC-005).

## Trust-boundary confirmation (Constitution X/XI)

- The kit runs **inside** the untrusted sandboxed body; its typing/validation is DX and early failure, never enforcement.
- The OpenAI surface adds a *wire format*, not a gate: same meter, same cap, same kill, same credential holder (broker), same `MODEL_KEY` scrub at the port boundary. The body never sees the model key.
- Plain in-body tools (golden task) cross **no** gate — they are local functions. Connector tools (which *do* cross the gate) stay on the native/`/v1/tool_calls` channel and are out of scope (13-02).
- No change to `gate.ex`, manifest semantics, capability render, or world-B invariants. A body that hand-rolls transport anyway is constrained exactly as before by sandbox + broker.

## Residual risks the tests must close

1. **Lazy tiktoken/asset fetch** under real container conditions → closed by Tier (c) `--network=none`.
2. **Hidden/uncommanded framework calls** → closed by Tier (a) broker-log reconciliation + Tier (b) call-for-call spend check.
3. **`sun_path` length** on macOS → fixtures keep socket paths short (bake-off hit this); kit surfaces a clear error if the path is too long.
4. **OpenAI response-shape drift** between stub and real upstream → tests use the stub (Constitution IV); real upstream shape is exercised only in live operator use, out of test scope.
