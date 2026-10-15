---
description: "Task list for Agent Runtime Kit (agent_os_runtime)"
---

# Tasks: Agent Runtime Kit (`agent_os_runtime`)

**Input**: Design documents from `/specs/046-agent-runtime-kit/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/openai-surface.md, contracts/kit-api.md, quickstart.md

**Tests**: REQUIRED — the spec mandates three test tiers (FR-011 Elixir E2E, FR-012 Python deterministic suite, FR-013 `--network=none` containment probe). Test tasks are included and, for backend logic, precede implementation (Constitution III).

**Organization**: Tasks are grouped by user story. US1 (kit + Python suite) and US2 (broker surface) are both P1; US1's Python tier is independently testable against a stub broker, US2 is independently testable at the broker level. The combined port-boundary E2E lives in US2's phase because it exercises US1's body against US2's broker.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: US1–US4 maps to the spec's user stories

## Path Conventions

- Kit: `agent_os_runtime/` (repo root, first-party trusted code)
- Bodies: `agents/<name>/` (untrusted workloads)
- Substrate: `lib/agent_os/`, tests `test/agent_os/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Package skeleton and dependency pin so both languages can build against the kit.

- [x] T001 Create the kit package skeleton: `agent_os_runtime/__init__.py` (empty exports stub), `agent_os_runtime/model.py`, `agent_os_runtime/invoke.py`, `agent_os_runtime/schema.py`, and `agent_os_runtime/tests/__init__.py`.
- [x] T002 Add `pydantic-ai-slim[openai]==2.5.0` (exact pin) to `pyproject.toml` dependencies and run `uv lock` to regenerate `uv.lock` with the frozen resolution (FR-008); do not add it to a dev-only group — it must ship in the image.
- [x] T003 [P] Confirm `ruff` and `mypy` see the new `agent_os_runtime/` package (add it to `[tool.mypy]`/ruff include if needed in `pyproject.toml`); no lint config regression.

**Checkpoint**: `uv sync` installs the framework; `import agent_os_runtime` resolves from repo root.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Typed payload/outcome schema and the seeded Python test harness that every later tier and story reuses.

**⚠️ CRITICAL**: No user-story work should begin until these exist.

- [x] T004 [P] Implement `agent_os_runtime/schema.py` — Pydantic `InvocationPayload` (`task: str|None`, `history: list[dict]|None`) and `OutcomeRecord` (`outcome: str`, `reason: str`, `history: list[dict]`) per data-model.md; docstrings + `mypy`-clean, no bare dicts (Constitution V).
- [x] T005 [P] Seed the Python test harness: copy + adapt `.planning/bakeoff-agent-framework/harness/socket_guard.py` → `agent_os_runtime/tests/socket_guard.py` (AF_UNIX-only egress jail) and `.planning/bakeoff-agent-framework/harness/broker.py` → `agent_os_runtime/tests/stub_broker.py` (scripted UDS broker speaking `/v1/chat/completions`); keep fixture socket paths short (AF_UNIX ~104-char limit, FR-013).
- [x] T006 Implement `agent_os_runtime/tests/conftest.py` — a pytest fixture that starts `stub_broker.py` on a short-path UDS, installs the socket jail, and yields the socket path + broker log path for reconciliation.

**Checkpoint**: A test can spin the stub broker + jail and point a client at the UDS.

---

## Phase 3: User Story 1 - Multi-step tool loop, zero transport code (Priority: P1) 🎯 MVP

**Goal**: A `<30`-line kit-based body runs the golden multi-step task over the UDS with no transport/env code.

**Independent Test**: `uv run pytest agent_os_runtime/tests/test_transport.py` — the sample body / kit completes `search_notes → add_todo → final Result` against the stub UDS broker; broker log shows exactly the commanded calls; body inspected is `<30` lines with zero socket/HTTP/env handling.

### Tests for User Story 1 (write first, expect fail)

- [x] T007 [P] [US1] Write `agent_os_runtime/tests/test_transport.py` — drives the golden 2-tool task through the kit against the stub broker over the UDS; asserts structured `Result` output, tool order, and call-for-call broker-log reconciliation (FR-012 / SC-001 / SC-003). Also asserts env-contract fail-fast: missing `RUN_TOKEN`/`INFERENCE_SOCKET`/`AGENT_MODEL` → structured failure, no call (FR-002/FR-009 / US1-3).
- [x] T008 [P] [US1] Write `agent_os_runtime/tests/test_retry.py` — stub broker in `malformed` mode returns invalid tool args; assert bounded retries (default 2), each a discrete broker request, ending in a structured failure outcome — no unbounded loop (FR-007/FR-009 / US1-4).

### Implementation for User Story 1

- [x] T009 [US1] Implement `substrate_model()` in `agent_os_runtime/model.py` — read `INFERENCE_SOCKET`/`RUN_TOKEN`/`AGENT_MODEL`; build `httpx.AsyncClient(transport=httpx.AsyncHTTPTransport(uds=…), base_url="http://localhost/v1")`; `OpenAIProvider(base_url=…, api_key=RUN_TOKEN, http_client=…)`; return `OpenAIChatModel(AGENT_MODEL, provider=…)`. Fail fast with a typed error on missing/empty vars or over-limit socket path (contracts/kit-api.md, FR-002/FR-009).
- [x] T010 [US1] Implement `run_agent(agent, …)` in `agent_os_runtime/invoke.py` — read one stdin line → `InvocationPayload`; call `agent.run_sync(task)`; emit `OutcomeRecord(outcome="completed", reason=…, history=…)` on success and `outcome="failed"` on any exception; never exit without a record (FR-005/FR-009). (History threading added in US3.)
- [x] T011 [US1] Wire `agent_os_runtime/__init__.py` to export `substrate_model` and `run_agent`.
- [x] T012 [US1] Create the golden sample body `agents/sample_kit_agent/main.py` (+ `models.py` if needed) — `<30` lines, zero transport/env code, `Agent(substrate_model(), output_type=Result, retries=2)` with `search_notes`/`add_todo` `@agent.tool_plain` functions and `run_agent(agent)` (FR-010 / SC-002); `ruff`/`mypy` clean.

**Checkpoint**: US1 Python tier green; sample body meets the `<30`-line / zero-transport acceptance.

---

## Phase 4: User Story 2 - Broker speaks native protocol, identical chokepoint (Priority: P1)

**Goal**: The broker exposes a single-turn `/v1/chat/completions` surface authenticated on the Bearer run token, mapping onto the exact metering/cap/kill path; the kit talks to it unmodified.

**Independent Test**: `mix test test/agent_os/inference_broker_openai_test.exs` — valid token → metered 200; bad token → 401 no spend; cap breach → 402 kill; N calls reconcile call-for-call; native `/v1/inference` + `/v1/tool_calls` unchanged.

### Tests for User Story 2 (write first, expect fail — backend logic, Constitution III)

- [x] T013 [P] [US2] Write `test/agent_os/inference_broker_openai_test.exs` — start broker via `start_broker_uds!/1` with a scripted `provider_fn`; POST OpenAI-shaped `/v1/chat/completions` over the UDS with `Authorization: Bearer <token>`; assert: valid→200 + ledger += exactly `micro_dollars(usage)`; missing/malformed/expired token→401 no provider call no spend; pre-cap→402; post-meter cross→402 kill; N calls→N ledger writes reconciling; native routes regression-unchanged (contracts/openai-surface.md, US2-1..5 / FR-003/FR-004 / SC-003).
- [x] T014 [P] [US2] Add a UDS POST helper for the OpenAI route to `test/test_helper.exs` (mirroring `submit_tool_calls_uds/2`) that sets the `Authorization: Bearer` header, so the broker test and E2E can frame requests without a Python container.

### Implementation for User Story 2

- [x] T015 [US2] Extend `read_http_request/2` and routing in `lib/agent_os/inference_broker.ex` to capture the `Authorization` header and thread it to `route_request`; add a `route_request(socket, "/v1/chat/completions", body, auth)` clause. Native path clauses stay byte-identical (FR-004).
- [x] T016 [US2] Implement `complete_openai/2` (single metered turn, NO server-side loop) in `lib/agent_os/inference_broker.ex` — parse Bearer token; `resolve/1`; `InferencePrice.lookup/2`; normalize window via `SpendLedger.current_entry/3`; pre-check cap→`{:breach,:spend}`; ONE `CredentialProxy.with_credential(:model_key, provider_fn.(model, messages, tools, secret))`; meter `micro_dollars`; `{:put, agent_name, entry}`; post-meter cap check; reuse the identical helpers the native path uses (research §Decision 3, contracts/openai-surface.md).
- [x] T017 [US2] Serialize the provider `message` + `usage` into an OpenAI `chat.completion` JSON (`choices[0].message`, `finish_reason`, `usage`) and map results to HTTP: 200 / 400 `unpriced_model` / 401 `unknown_run_token` / 402 `spend_breach` / 400 malformed/`stream:true`-unsupported (data-model.md error table); typespecs + `@doc`, Dialyzer-clean.

### Combined port-boundary E2E (exercises US1 body against US2 broker — FR-011)

- [x] T018 [US2] Write `test/agent_os/runtime_kit_e2e_test.exs` — `start_broker_uds!/1` with a scripted golden `provider_fn`; run `agents/sample_kit_agent/main.py` via `.venv/bin/python` (`:agent_cmd`/`:agent_args` override) across the port boundary with the injected env contract; assert: golden multi-step task completes; exactly one outcome-record line on stdout (`outcome`/`reason` [+`history`]); call-for-call spend reconciliation against the broker/ledger (FR-011 / SC-001/SC-003).

**Checkpoint**: US2 broker tests + the combined E2E green; native path proven unchanged.

---

## Phase 5: User Story 3 - History in, delta out (Priority: P2)

**Goal**: The invocation wrapper is session-shaped: optional `history` threaded into the model; the run's new-message delta on the outcome record. No body changes.

**Independent Test**: `uv run pytest agent_os_runtime/tests/test_history.py` — run the sample body twice; second run fed the first run's delta demonstrably continues the conversation and returns only the new delta.

### Tests for User Story 3 (write first)

- [x] T019 [P] [US3] Write `agent_os_runtime/tests/test_history.py` — (a) no `history` → full new-message set in the delta; (b) prior delta fed back → model receives prior messages, outcome carries only the new delta; (c) malformed `history` → fail-fast structured failure, no silent truncation (FR-006/FR-009 / US3-1..3).

### Implementation for User Story 3

- [x] T020 [US3] Extend `run_agent` in `agent_os_runtime/invoke.py` — if `payload.history` present, deserialize via pydantic-ai's `ModelMessagesTypeAdapter` and pass as `message_history=` to `run_sync`; malformed → structured failure (research §Decision 5). Never persist (Constitution IX).
- [x] T021 [US3] Populate the outcome record's `history` with `result.new_messages()` serialized (the delta only), in both fresh and resumed runs (data-model.md OutcomeRecord).

**Checkpoint**: History tier green; the same body works as a future chat turn.

---

## Phase 6: User Story 4 - Pinned, baked, provably offline (Priority: P2)

**Goal**: Kit + framework baked into the generated-agent image at build time (exact pins); a `--network=none` run of the sample body completes the golden task with zero egress and no lazy downloads.

**Independent Test**: build `agent-generated:dev`; `docker run --network=none` the sample body with only the UDS mounted; golden success + zero egress + no tiktoken fetch.

### Implementation for User Story 4

- [x] T022 [US4] Edit `agents/generated.Dockerfile` — the `uv sync --frozen --no-dev` layer now installs the pinned framework (from T002); add `COPY agent_os_runtime ./agent_os_runtime` (before `chown`) so `import agent_os_runtime` resolves on the baked `PYTHONPATH=/app` (FR-008). No agent-provision-time install.
- [x] T023 [US4] Build the image (`docker build -f agents/generated.Dockerfile -t agent-generated:dev .`) and assert installed packages show the kit + `pydantic-ai-slim==2.5.0` at exact pins and that no provision-time install occurs (SC-005 / US4-1).
- [x] T024 [US4] Extend the spec-044 containment probe to run `agents/sample_kit_agent/main.py` under `--network=none` with only the UDS mounted against a stub/test broker; assert golden-task success, zero egress attempts, and no lazy asset downloads (tiktoken never fetches) (FR-013 / SC-004 / US4-2). Keep the probe socket path short.
- [x] T025 [P] [US4] Document the Python kit suite (`agent_os_runtime/tests`) as the mandatory regression gate for any framework pin bump — a short `agent_os_runtime/README.md` section referencing quickstart.md Tier (a) (FR-012 / SC-005 / US4-3).

**Checkpoint**: Offline guarantee proven in-image; pin + regression gate documented.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Prove nothing else regressed and the whole thing is clean.

- [x] T026 [P] Run `uv run ruff check . && uv run mypy agent_os_runtime && uv run pytest agent_os_runtime/tests` — Python side fully green/clean (Constitution V, Quality Gates).
- [x] T027 Run `mix format --check-formatted && mix credo && mix test` — full Elixir suite incl. the world-B suite green and unchanged; existing native-path agents unchanged (SC-006/SC-007 / FR-014). Fix ALL failing tests, not just feature-related ones.
- [x] T028 [P] Run the quickstart.md three-tier walkthrough end to end and confirm each tier's asserted outcomes.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (P1)**: no deps.
- **Foundational (P2)**: depends on Setup; blocks all stories.
- **US1 (P3)**: depends on Foundational. Independently testable via the stub broker (no Elixir needed).
- **US2 (P4)**: depends on Foundational; the broker-level tests are independent of US1, but the combined E2E (T018) additionally depends on US1 (sample body).
- **US3 (P5)**: depends on US1 (extends `run_agent`).
- **US4 (P6)**: depends on US1 (sample body) + T002 pin; independent of US2/US3.
- **Polish (P7)**: depends on all desired stories.

### Within Each User Story

- Tests before implementation for backend logic (Constitution III).
- `schema.py` (Foundational) before `model.py`/`invoke.py`.
- Broker route capture (T015) before `complete_openai` (T016) before serialization/mapping (T017) before E2E (T018).

### Parallel Opportunities

- T003 alongside T002; T004/T005 in parallel; test-writing tasks T007/T008, T013/T014, T019 marked [P].
- After Foundational: US1 (Python) and US2 (broker unit tests T013–T017) can proceed in parallel; only the E2E (T018) joins them.
- US4 Dockerfile/offline work is independent of US2/US3 once US1's sample body exists.

---

## Parallel Example: User Story 1

```bash
# Tests first (parallel):
Task: "Write agent_os_runtime/tests/test_transport.py"
Task: "Write agent_os_runtime/tests/test_retry.py"
# Then implementation (model → invoke → export → sample body).
```

---

## Implementation Strategy

### MVP First (US1 + US2)

Both are P1. Deliver US1 (kit + Python tier-a proving transport/retry against the stub broker) and US2 (broker surface + broker-level tests), then the combined E2E (T018) — that is the load-bearing "kit drives the real broker across the port boundary" proof.

### Incremental Delivery

1. Setup + Foundational → package builds, harness ready.
2. US1 → Python tier green, sample body meets acceptance (MVP demo).
3. US2 → broker surface + E2E green (chokepoint parity proven).
4. US3 → history in/out (session-shaped).
5. US4 → baked + offline proof + regression-gate docs.
6. Polish → world-B + full suites green, nothing regressed.

---

## Notes

- [P] = different files, no incomplete-task dependency.
- Trust boundary unchanged: the kit is DX; no task touches `gate.ex`, manifest semantics, capability render, or world-B invariants (FR-014).
- Connector tool-stub codegen (13-02), Stage-4/judge/security-review (13-03), and history persistence + chat routing (Phase 14) are OUT of scope — do not implement.
- Do not commit; leave changes in the working tree.
