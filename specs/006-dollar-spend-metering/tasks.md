# Tasks: Dollar Spend Metering via an Inference Chokepoint

**Input**: Design documents from `specs/006-dollar-spend-metering/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: INCLUDED. Constitution III mandates test-first backend logic; the spec requires
deterministic verification (mock provider, fixed price table, small cap, injected `:now`). The
Python inference shim and the live UDS transport are NOT unit-tested (Constitution III/IV) — they
are integration / manual-walkthrough only.

**Organization**: Tasks are grouped by the four user stories so each is independently implementable
and testable. All dollar quantities are **integer micro-dollars** (FR-009).

## Path Conventions

Single project, BEAM control plane (`lib/agent_os/`, `test/agent_os/`) + Python workload
(`agents/discovery/`). Paths below are repo-root relative.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Config surface the broker and run-worker both depend on.

- [ ] T001 Add the per-model price table `:inference_prices` to the test block of `config/config.exs` as integer micro-dollars (e.g. `%{"mock-model" => %{input: 10, output: 30}}`); leave a documented prod placeholder entry for the real Gemini 3-series model.
- [ ] T002 Add the inference credential `:model_key` to the **prod** `:credentials` map in `config/config.exs`, sourced from OS env (`System.get_env("MODEL_KEY")`); confirm the test block already provides `model_key` (it does). (T001 and T002 both edit `config/config.exs` — do them in one sitting; NOT parallel.)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Re-denominate the existing spend units to micro-dollars so inference dollars and
per-action dollars share one coherent budget. This MUST land before the story phases because it
changes the meaning of `cost`/`cap` everywhere. ⚠️ It will shift existing 005 test expectations.

- [ ] T003 Re-denominate the `cost` field of every entry in the `@registry` in `lib/agent_os/connector.ex` to integer micro-dollars: `kv_append` → `0` (free, local state write); `external_send` → an explicit representative paid-API cost of `2_000` µ$ ( = $0.002) so US3 has a concrete real-dollar per-action instance to meter (it stands in for a connector whose downstream call costs money). Update the `@type capability` doc/comment to state the unit and that `0` means free.
- [ ] T004 Re-express `spend.cap` as a chosen **dollar budget** in micro-dollars (the old `cap: 5` was arbitrary units with no equivalence; pick a real budget, e.g. `$0.50 = 500_000` µ$) in `manifests/discovery.md` and in the `config :agent_os, :agent` block of `config/config.exs`; keep `window: :daily` / `on_breach: :kill` and `spend_defaults` unchanged.
- [ ] T005 Update existing spend-related test expectations to micro-dollars so the suite stays green after T003/T004: `test/agent_os/connector_test.exs`, `test/agent_os/gate_test.exs`, and the spend/cap cases in `test/agent_os/run_supervisor_test.exs` (cost sums, cap-boundary values).

**Checkpoint**: `mix test` green with the re-denominated units; no inference logic yet.

---

## Phase 3: User Story 1 — Inference dollars metered trustlessly at the broker (Priority: P1) 🎯 MVP

**Goal**: Each model call routes through the substrate broker, which meters provider-reported
tokens × config price into the per-agent ledger in micro-dollars; the agent sees only the
completion and holds no key.

**Independent Test**: Drive `InferenceBroker.complete/2` with a mock `provider_fn` and a fixed price
table; assert the metered µ$ equals `in_tokens·in_price + out_tokens·out_price`, the result carries
only `:completion`, and an unpriced model / unknown token fails closed — all with no live LLM.

### Tests (write first — must fail)

- [ ] T006 [US1] Write failing `test/agent_os/inference_broker_test.exs`: (a) price math — canned `usage` × fixed `:prices` ⇒ exact µ$ summed into `spend_ledger`; (b) invisibility — success result has only `:completion` (no `:price`/`:cap`/`:usage`/`:spent`); (c) fail-closed — unpriced model ⇒ `{:error, :unpriced_model}` with `provider_fn` NOT invoked, unknown token ⇒ `{:error, :unknown_run_token}`; (d) **one-call overshoot** (FR-014) — with `spent` just below cap, a call that crosses ⇒ `provider_fn` invoked exactly once, result `{:breach, :spend}`, and final `spent` exceeds cap by exactly that call's metered cost (no pre-estimation); (e) **pre-check refusal** — with `spent >= cap`, the next call ⇒ `{:breach, :spend}` with `provider_fn` NOT invoked. Use a mock `provider_fn`, fixed `:prices`, injected `:now`.

### Implementation

- [ ] T007 [P] [US1] Implement the pure price helper `lib/agent_os/inference_price.ex`: `lookup/2` (table + model ⇒ `{:ok, %{input, output}}` | `{:error, :unpriced_model}`) and `micro_dollars/2` (`usage` × price entry ⇒ integer µ$). `@spec` + `@doc`; no side effects.
- [ ] T008 [US1] Implement `AgentOS.InferenceBroker` in `lib/agent_os/inference_broker.ex` as a GenServer holding the per-run token registry (`register/3` token→`{agent_name, manifest}`, `unregister/1`, server-side `resolve`), plus `complete/2` per [contracts/inference-broker.md](./contracts/inference-broker.md): resolve token → look up price (fail closed) → `SpendLedger.current_entry/3` window reset (persist if changed) → **pre-check** `spent >= cap` ⇒ `{:breach, :spend}` → `CredentialProxy.with_credential(:model_key, …)` calling the injectable `provider_fn` → compute µ$ → persist `spent + dollars` via `StateStore` (single writer) → **post-meter check** ⇒ `{:breach, :spend}` (one-call overshoot) else `{:ok, %{completion: …}}`. Make `:now`, `:provider_fn`, `:prices` injectable. `@type request/usage/result` typespecs.
- [ ] T009 [US1] Run T006 to green; assert no price/cap/usage/spent leaks in the success path and that `:model_key` is never returned, logged, or persisted (004 invariant).
- [ ] T010 [US1] Register `AgentOS.InferenceBroker` in the supervision tree in `lib/agent_os/application.ex`, guarded by the existing `autostart` flag like other singletons (not started in `:test`).
- [ ] T011 [US1] Implement the local HTTP listener for the broker (`POST /v1/inference` over the mounted unix-domain socket; OTP stdlib `:inets`/`:gen_tcp`, no new dep) delegating to `complete/2` and mapping results to the wire responses in [contracts/broker-boundary.md](./contracts/broker-boundary.md) (`200 {completion}`, `402 {error: spend_breach}`, `4xx {error: unpriced_model|unknown_run_token}`).
- [ ] T012 [US1] In `lib/agent_os/run_worker.ex` + `lib/agent_os/sandbox.ex`: generate a per-run broker token, `register/3` it with the broker before the run and `unregister/1` after, inject it into the container env, and mount the broker UDS into the sandbox in `Sandbox.build_argv` while keeping `network: "none"` (egress limited to the broker socket; agent cannot widen it).
- [ ] T013 [P] [US1] Update `agents/discovery/main.py` to read the per-run token from env and route any model call through the broker socket (no provider key on the agent). `ruff` + `mypy` clean. (Integration/manual-walkthrough; not unit-tested.)

**Checkpoint**: US1 deterministic tests pass; the broker is the sole, key-holding inference path.

---

## Phase 4: User Story 2 — Runaway inference loop killed with zero proposed actions (Priority: P1)

**Goal**: Cumulative inference dollars crossing the cap kill the run even when the agent proposed
zero actions, and further inference is refused — the runaway-bill case 005 missed.

**Independent Test**: Seed `spend_ledger[agent].spent >= cap`; run with an empty/any action batch ⇒
`{:killed, :spend_breach}`, no actions executed, `RunSupervisor` does not restart; a genuine crash
still restarts once. Repeated broker calls past the cap all return `{:breach, :spend}`.

### Tests (write first — must fail)

- [ ] T014 [US2] Add failing cases to `test/agent_os/run_supervisor_test.exs`: (a) seed `spent >= cap`, `RunWorker.run_once/1` with zero/any actions ⇒ `{:killed, :spend_breach}`, no `Effector` call, supervisor restart NOT invoked (reuse 005 restart-exemption spy); (b) a genuine abnormal exit still ⇒ `{:error, _}` ⇒ restart-once (regression); (c) runaway-loop property — once `spent >= cap`, repeated `complete/2` calls (simulating the loop) add **no further** µ$ to the ledger and the bill stops (the unit pre-check itself is asserted in T006e).

### Implementation

- [ ] T015 [US2] Add the pre-gate inference-only breach branch to `lib/agent_os/run_worker.ex` per [contracts/run-worker-spend.md](./contracts/run-worker-spend.md): after computing the windowed entry, `if spent >= cap` call the existing `dispatch_on_breach(:kill, …)` (returning `{:killed, :spend_breach}`) and drop the whole batch — before `Gate.partition_batch`. Log the existing `status=killed failure_cause=spend_breach` line.
- [ ] T016 [US2] Run T014 to green; confirm the broker's pre-check refusal (from T008) stops further inference the instant the cap is crossed and that the intentional-stop signal is distinct from a crash.

**Checkpoint**: US1 + US2 = the MVP (real dollar metering + runaway protection).

---

## Phase 5: User Story 3 — Per-action dollars summed into the same dollar ledger (Priority: P2)

**Goal**: A connector with a real per-action dollar cost contributes to the **same** ledger entry
against the **same** cap as inference dollars — one budget, two sources.

**Independent Test**: Seed inference dollars below cap; a run whose approved action dollars push the
combined `spent` over the single cap ⇒ killed; a within-budget combined run executes and increments
the one ledger.

### Tests (write first — must fail)

- [ ] T017 [US3] Add failing cases to `test/agent_os/run_supervisor_test.exs`: (a) seed `spent` (inference) below cap, run an approved action whose µ$ cost pushes combined `spent` over the cap ⇒ `{:killed, :spend_breach}` against the single cap; (b) a combined run within budget executes and the post-gate increment lands in the same `spend_ledger` entry.

### Implementation

- [ ] T018 [US3] Verify/adjust the post-gate increment in `lib/agent_os/run_worker.ex` so `total_approved_cost` uses the µ$ registry `cost` (T003) and writes to the same `spend_ledger[agent_name].spent` (no second store, no second cap); make T017 green.

**Checkpoint**: One dollar budget reflects inference + per-action spend.

---

## Phase 6: User Story 4 — Window reset + per-agent dollar visibility (Priority: P2)

**Goal**: Dollar spend resets at the fixed window boundary (005 reused) and the operator sees
per-agent spent / cap / window in **dollars** on the standing inventory, read from the ledger.

**Independent Test**: After accruing µ$, advancing injected `:now` past the boundary resets `spent`
to 0; the inventory render shows spent/cap in dollars sourced from the ledger, never the agent.

### Tests (write first — must fail)

- [ ] T019 [US4] Add failing cases to `test/agent_os/inventory_test.exs`: per-agent spent/cap rendered in **dollars** from the persisted `spend_ledger` (no agent contact); spent shown as `$0.00` after a window reset (advance `:now` past the boundary).

### Implementation

- [ ] T020 [US4] Implement dollar formatting in `lib/agent_os/inventory.ex` (µ$ → `"$0.000500"`-style), reusing the existing spend-render read path from 005; do not change what is read, only the unit shown.
- [ ] T021 [US4] Run T019 to green; confirm the window-reset-in-dollars case reuses `SpendLedger.current_entry/3` unchanged (005 semantics).

**Checkpoint**: All four stories complete; spend is real dollars end-to-end.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T022 [P] Ensure every new function carries `@doc`/`@moduledoc` and that the price-math, pre/post cap-check, and identity-binding blocks carry intent comments (Constitution VII) in `inference_broker.ex`, `inference_price.ex`, and the new `run_worker.ex` branch.
- [ ] T023 [P] `mix format` + `Credo` clean; `Dialyzer` clean (request/usage/price/result typespecs sound).
- [ ] T024 [P] `ruff` + `mypy` clean for `agents/discovery/main.py`.
- [ ] T025 Run the full `mix test` suite and fix ANY remaining 004/005 tests affected by the µ$ re-denomination so the entire suite is green (global rule: fix all failing tests, not just this feature's).
- [ ] T026 Manual walkthrough of the live UDS boundary + Python shim per [quickstart.md](./quickstart.md) ("What is NOT tested") — confirm the agent routes through the broker, holds no key, and receives only completions; egress limited to the broker socket.

---

## Dependencies & Execution Order

- **Setup (T001–T002)** → no dependencies; do first.
- **Foundational (T003–T005)** → depends on Setup; **blocks all stories** (changes cost/cap unit).
- **US1 (T006–T013, P1)** → depends on Foundational. The deterministic MVP core.
- **US2 (T014–T016, P1)** → depends on US1 (uses the broker's per-call meter/pre-check and the
  shared ledger). Together US1+US2 = MVP.
- **US3 (T017–T018, P2)** → depends on Foundational (µ$ cost) + the shared ledger from US1.
- **US4 (T019–T021, P2)** → depends on US1 (something to render) + 005's `SpendLedger` (reused).
- **Polish (T022–T026)** → after all stories.

Story independence: US3 and US4 are independent of each other and can proceed in parallel once US1
lands. US2 is the only story with a hard dependency on US1's broker semantics.

## Parallel Opportunities

- Setup: **T001 + T002 are NOT parallel** — both edit `config/config.exs`; do them together.
- US1: **T007 (price helper) ∥ T013 (Python shim)** — different files; both independent of T008's
  broker wiring. T006 (tests) is written before T007–T009.
- Polish: **T022 ∥ T023 ∥ T024** — docs/Elixir-lint/Python-lint are independent.

## Implementation Strategy

- **MVP = US1 + US2** (both P1): real dollar metering at the broker plus runaway-bill protection —
  the operator's core need. Ship and validate this first.
- **Increment 2 = US3** (per-action dollars in the one budget), **then US4** (window reset already
  works via 005; add the dollar render). Both P2, both small, independent.
- Keep the suite green after Foundational (T005) and after each story checkpoint; do not let the µ$
  re-denomination leave 004/005 tests red (T025 is the backstop).
