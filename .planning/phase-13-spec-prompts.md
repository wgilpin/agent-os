# Phase 13 — Spec Prompts (Agent Runtime Kit, v12)

Drafted `/speckit-specify` prompts for the Phase 13 plans. Decision record and phase detail
in [ROADMAP.md](ROADMAP.md) (Phase 13); empirical evidence and the re-runnable regression
harness in [bakeoff-agent-framework/](bakeoff-agent-framework/). Paste each prompt after
`/speckit-specify` when starting that plan. 13-01 drafted below; 13-02 and 13-03 are drafted
plan-by-plan when each is started.

> **Framework decision (2026-07-12):** `pydantic-ai-slim[openai]==2.5.0`, pinned exact,
> chosen by bake-off against a ~200-line no-framework baseline (both passed all gating
> criteria; see [bakeoff-agent-framework/SCORECARD.md](bakeoff-agent-framework/SCORECARD.md)).
> The no-framework loop is the kept exit ramp: bodies import only the kit, so a framework
> swap is a kit release, not a generation-contract change. A version bump is a deliberate
> event: harness re-runs green + a golden agent regenerates through the full pipeline first.

---

## 13-01 — `agent_os_runtime` package + SubstrateModel (transport into the kit)

```
/speckit-specify Create `agent_os_runtime`, a first-party Python runtime kit baked into the generated-agent image, so generated agent bodies stop hand-rolling raw HTTP-over-UDS transport and gain a framework-grade agent loop (typed tools, bounded retries, structured output, message history) — while the trust boundary stays exactly where it is: the kit is DX, the gate and sandbox remain the only enforcement.

## Problem
Every generated agent body re-invents ~40 lines of raw AF_UNIX HTTP/1.1 socket code and makes exactly one inference call (see agents/get_the_local_time_*/main.py `call_inference_broker/2` — hand-rolled request assembly, header parsing, status handling, freshly LLM-generated per agent). This is a per-agent bug surface, it makes multi-step tool-loop agents impossible to generate reliably, and it bloats what Stage 4 emits and what the judge and Stage-5 security review must audit. The framework decision is already made empirically (pydantic-ai-slim[openai]==2.5.0 — .planning/bakeoff-agent-framework/SCORECARD.md): first-class UDS transport via `httpx.AsyncHTTPTransport(uds=...)` into `OpenAIProvider(http_client=...)`, offline-total under an AF_UNIX-only jail, zero uncommanded calls, retries bounded and visible. This plan lands the kit and the transport; tool-stub codegen from the connector registry is 13-02 and the Stage-4 generation contract is 13-03.

## Desired behaviour
A Python package `agent_os_runtime` (location: a new top-level Python package dir alongside `agents/`, owned by the substrate repo, NOT generated) that a generated body uses as:

    from agent_os_runtime import substrate_model, run_agent
    from pydantic_ai import Agent
    agent = Agent(substrate_model(), instructions=..., output_type=MyResult)

- `substrate_model()` returns a pydantic-ai Model speaking to the inference broker over the mounted UDS, reading the existing agent env contract (`INFERENCE_SOCKET`, `RUN_TOKEN`, `AGENT_MODEL`) — the same env the sandbox already injects (lib/agent_os/sandbox.ex / run_worker.ex). The proven shape: `OpenAIChatModel(AGENT_MODEL, provider=OpenAIProvider(base_url=..., http_client=httpx.AsyncClient(transport=httpx.AsyncHTTPTransport(uds=INFERENCE_SOCKET))))` (bake-off snippet, .planning/bakeoff-agent-framework/candidates/run_pydai.py).
- **Broker compatibility decision the spec must resolve:** the OpenAI provider POSTs OpenAI-shaped chat-completions JSON to `/v1/chat/completions` with the key in an `Authorization: Bearer` header, while the broker's native envelope is POST `/v1/inference` with `run_token` in the JSON body (lib/agent_os/inference_broker.ex). Preferred resolution: the broker gains an OpenAI-compatible `/v1/chat/completions` surface that reads the run token from the Authorization header (`api_key=RUN_TOKEN` on the provider) and maps onto the existing metering/validation path — keeping the framework untouched and the chokepoint semantics identical (same spend metering, same per-call cap, same kill-on-breach). The alternative (kit-side request rewriting via httpx event hooks) is brittle against framework upgrades; reject it unless the spec finds a hard blocker.
- **Session-shaped invocation from day one:** `run_agent(agent, payload)` wraps the existing PortRunner stdin/stdout contract (one JSON line in via stdin-guard, one outcome-record line out) and adds: message history IN (optional `history` field in the input payload) and history delta OUT (new messages appended to the outcome record), so a future chat-turn agent (Phase 14) is the same body invoked with history — no body changes. The substrate persists history; the kit only threads it through pydantic-ai's message-history API.
- **Pinned and baked:** `pydantic-ai-slim[openai]==2.5.0` and the kit are installed into the generated-agent runtime image (agents/generated.Dockerfile, spec 044) at build time — exact pins, no floating, no install at agent-provision time.
- **Bounded, visible retries:** the kit sets an explicit retry budget (bake-off default `retries=2`) so every model/tool retry is a discrete metered broker request; no framework feature that issues uncommanded calls may be enabled.

## Trust boundary (unchanged — state this in the spec)
The kit runs INSIDE the untrusted sandboxed body. Its typing/validation is developer experience and early failure, never enforcement: the gate still validates every action against the manifest, the broker still meters every call, and the sandbox (network=none; the UDS is the only reachable endpoint) physically disables pydantic-ai's native tools / MCP / direct-provider egress. Nothing in this plan touches lib/agent_os/gate.ex, manifest semantics, or the world-B invariants.

## Testing (Constitution IV — deterministic, no network)
- Reuse the existing broker test helper (`start_broker_uds!/1` in test/test_helper.exs) for an Elixir-side E2E: a sample kit-based agent body runs across the port boundary against a test broker instance and completes a golden multi-step tool task (the bake-off's search_notes → add_todo → final_result script is the reference shape).
- Python-side: the bake-off harness (.planning/bakeoff-agent-framework/harness/) is the seed — stub UDS broker + AF_UNIX-only socket jail; adopt/adapt it as the kit's test suite so it doubles as the version-bump regression gate.
- In-image offline validation: a `--network=none` container run of the sample kit-based agent completes the golden task with zero egress attempts (extends the spec-044 containment probe). Keep socket paths short — macOS caps AF_UNIX `sun_path` at ~104 chars.

## Acceptance criteria
- A sample agent body of < 30 lines (imports, models, `Agent(...)`, `run_agent(...)`) completes a multi-step (2+ sequential tool calls) golden task against a test broker over the UDS, inside the sandboxed container, with history threaded in and delta out.
- The body contains zero transport code and zero socket/env handling; `agents/*/main.py`-style hand-rolled HTTP does not appear.
- Broker-side: every model call and retry from the kit appears as a discrete metered request; spend reconciles call-for-call with the broker log; the per-call cap and kill-on-breach behave identically to the native envelope path.
- The `--network=none` in-image run passes with zero egress attempts and no lazy asset downloads (tiktoken sits in the dep tree; prove it never fetches).
- Versions are pinned exact in the image; the regression harness runs green and is documented as the gate for any future pin bump.
- World-B suite unchanged and green; no change to gate, manifest projection, or capability render.

## Out of scope
- Tool-stub codegen from the connector registry and the `/v1/tool_calls` channel binding (13-02) — the golden task's tools may be plain in-body `@agent.tool_plain` functions for now.
- Any change to Stage 4 generation prompts, the judge, or security review (13-03); existing generated agents keep working on the native envelope path.
- Multi-agent routing, conversation orchestration, or persistence of history (Phase 14 owns the chat surface; this plan only shapes the kit's contract).
- Framework swap machinery beyond the seam itself (the no-framework fallback stays in .planning/bakeoff-agent-framework/ as evidence, not shipped code).
```
