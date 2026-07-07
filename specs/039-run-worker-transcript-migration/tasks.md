# Tasks: Run-Worker Transcript Migration

**Input**: Design documents from `specs/039-run-worker-transcript-migration/`
**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/outcome-record.md](contracts/outcome-record.md)

**Tests**: INCLUDED. Constitution III mandates test-first for backend logic, and this
feature exists because the current tests never drove the real (outcome-record) contract.
Every user story is RED-first.

**Organization**: Tasks grouped by user story (spec.md priorities). US1 and US2 are both
P1 and both mutate `execute_run/5` in the same file — they are sequential, not parallel.

## Path Conventions

Single Elixir/OTP project. Control plane under `lib/agent_os/`, tests under
`test/agent_os/`, fixtures under `test/fixtures/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: No new project scaffolding needed; establish the seam the story tests require.

- [x] T001 Confirm working tree is on branch `039-run-worker-transcript-migration` and `mix test` is green as a baseline before changes.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The typed outcome record and the run-token test seam. Every user story depends on both.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T002 [P] Write RED unit test `test/agent_os/outcome_record_test.exs` for `AgentOS.OutcomeRecord.parse/1` covering the accept/reject table in [contracts/outcome-record.md](contracts/outcome-record.md): accepts `{"outcome","reason"}` (incl. empty reason), rejects legacy `{"actions": []}`, missing key, non-string `outcome`, non-JSON, and empty stdout — all `{:error, :malformed}`.
- [x] T003 Create `lib/agent_os/outcome_record.ex`: `AgentOS.OutcomeRecord` struct (`outcome :: String.t()`, `reason :: String.t()`) with `@moduledoc`/`@doc`/`@spec` and `parse/1 :: {:ok, t()} | {:error, :malformed}`; make T002 GREEN.
- [x] T004 Add a test seam in `lib/agent_os/run_worker.ex` so the internally-generated `run_token` is injectable/observable in tests (e.g. honor `Keyword.get(opts, :run_token)` in `run_once/1`, falling back to `Base.encode16(:crypto.strong_rand_bytes(16))`), so story tests can pre-seed the `action_transcript` store deterministically. Keep the production default unchanged.

**Checkpoint**: `OutcomeRecord` parses/rejects correctly and tests can control the run token — user stories can begin.

---

## Phase 3: User Story 1 - Generated agent run is recorded correctly (Priority: P1) 🎯 MVP

**Goal**: `RunWorker` reads outcome from stdout and the effect tally from the transcript; real generated runs stop being misclassified as malformed.

**Independent Test**: Stub agent cmd prints `{"outcome":"completed","reason":"..."}`; pre-seed transcript with 2 granted + 1 rejected entries for the run token; assert run `:ok`, `actions=2`, `rejected_count=1`, not malformed. No live model.

- [x] T005 [US1] In `test/agent_os/run_worker_transcript_test.exs` (new), add setup that starts `action_transcript`, `spend_ledger`, and `pending_approvals` StateStores and runs `RunWorker.run_once/1` with an `agent_cmd` stub echoing a fixed outcome-record line and an injected `:run_token`.
- [x] T006 [US1] Add RED test: outcome record + transcript(2 granted, 1 rejected) ⇒ run log `status: :ok`, `actions`/`approved_count == 2`, `rejected_count == 1`, `gate_reasons` = the rejected reason codes, and NOT flagged malformed.
- [x] T007 [US1] Add RED test (spec US1 scenario 2): valid outcome record + empty transcript ⇒ run log `:ok` with zero effect counts, no error.
- [x] T008 [US1] Add RED test (spec US1 scenario 3 + Edge): stdout `{"actions": []}` (legacy) and non-record stdout ⇒ run log `:error`, `failure_cause: "malformed_outcome"`, distinct from `:ok`. Seed a POPULATED transcript for the run token and assert it is left intact after the malformed run (FR-008 edge: already-recorded effects are not undone).
- [x] T009 [US1] Rewrite the happy path of `execute_run/5` in `lib/agent_os/run_worker.ex`: replace the `%{"actions" => actions} <- Jason.decode!(stdout)` match with `OutcomeRecord.parse/1`; on `{:error, :malformed}` append a `:error` run log with `failure_cause: "malformed_outcome"` and a note naming the retired protocol.
- [x] T010 [US1] In the same `:ok` branch, read `AgentOS.ActionTranscript.read(run_token)` and derive `approved_count` (granted), `parked_count` (parked), `rejected_count` (rejected), and `gate_reasons` (unique `reason_code` of rejected) per [data-model.md](data-model.md); feed them to the existing `RunLog.append/2` fields. Make T006–T008 GREEN.

**Checkpoint**: Real generated runs are recorded correctly (SC-001). MVP delivered.

---

## Phase 4: User Story 2 - No double execution of effects (Priority: P1)

**Goal**: The worker never re-gates or re-executes effects; each granted effect produces exactly one side effect (the rail's).

**Independent Test**: Seed transcript with one granted effect whose connector counts invocations; run worker; assert the connector was invoked zero additional times by the worker.

- [x] T011 [US2] Add RED test in `test/agent_os/run_worker_transcript_test.exs`: seed a granted transcript entry for a connector instrumented to count invocations; assert `RunWorker` performs zero additional invocations (side effect count unchanged by the worker) and builds its run log without calling `Gate.partition_batch`/`Effector.act_all`. Also assert the transcript entry count is identical before and after `run_once` (FR-011: the worker reads the transcript and never mutates it — single-writer invariant from the reader side).
- [x] T012 [US2] Remove the second gate/execute block from `execute_run/5` in `lib/agent_os/run_worker.ex`: delete the `AgentOS.Gate.partition_batch` call, the `Effector.act_all(approved)` call, and the `total_approved_cost` ledger `{:put,…}` update (broker already charges tool cost during inference — see [research.md](research.md) Finding 2). Drop now-unused aliases/vars. Make T011 GREEN.

**Checkpoint**: Exactly-once execution guaranteed (SC-002); the double-execution hazard is gone.

---

## Phase 5: User Story 3 - Spend and breach accounting preserved (Priority: P2)

**Goal**: Spend and breach handling still work, sourced from the transcript + broker-updated ledger.

**Independent Test**: Seed transcript + `spend_ledger` at/over cap; run worker; assert run recorded breached and breach policy applied. Under cap ⇒ recorded within budget with ledger-accurate spend.

- [x] T013 [US3] Add RED test: post-run `spend_ledger` `spent >= manifest.spend.cap` ⇒ run log `status: :killed`, `failure_cause: :spend_breach`, `gate_reasons: [:spend_breach]`, with `rejected_count`/`parked_count` derived from the transcript (not a decoded action list).
- [x] T014 [US3] Add RED test: spend under cap ⇒ run `:ok` and reported spend equals the ledger entry for the run token.
- [x] T015 [US3] Update the mid-run breach branch and `dispatch_on_breach/9` callers in `lib/agent_os/run_worker.ex` to pass transcript-derived counts (`rejected`/`parked` from `ActionTranscript.read/1`) instead of the removed `Gate.partition_batch` outputs; preserve `dispatch_on_breach`'s RunLog field shape. Make T013–T014 GREEN.

**Checkpoint**: Spend/breach parity verified against seeded fixtures (SC-003).

---

## Phase 6: User Story 4 - Approval-required effects remain human-gated (Priority: P2)

**Goal**: Parked effects appear once in the run log without the worker re-parking or duplicating them.

**Independent Test**: Seed transcript with one parked entry + a matching request already in `pending_approvals`; run worker; assert run log shows 1 parked and the queue still holds exactly 1 (no duplicate).

- [x] T016 [US4] Add RED test: transcript with 1 parked entry and `pending_approvals` already holding 1 matching request ⇒ run log `parked_count == 1` AND `pending_approvals` still has exactly 1 entry after the run (worker adds none).
- [x] T017 [US4] Remove the `pending_approvals` insertion loop from `execute_run/5` in `lib/agent_os/run_worker.ex` (the rail already parks during inference — [research.md](research.md) Finding 3); derive `parked_count` from the transcript only. Make T016 GREEN.

**Checkpoint**: Approval gating single-sourced; no duplicate parks (SC-004).

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Retire the old contract from existing tests/fixtures and verify the whole suite.

- [x] T018 [P] Update `test/fixtures/generation/generation.ex`: `stub_agent_body` prints `{"outcome": "completed", "reason": "..."}` instead of `OutputModel(actions=[])`; change `models.py` to describe the outcome record only (remove `ActionEntry`/`OutputModel.actions`).
- [x] T019 [P] Migrate `test/agent_os/run_supervisor_test.exs` off the `{"actions"}` stubs and `actions=N` assertions to outcome-record stdout + transcript-seeded expectations (happy path, ungranted-drop, and the exact-cap spend cases).
- [x] T020 [P] Update `test/agent_os/port_runner_test.exs` so the stdout assertion (currently `=~ "actions"`) expects the outcome-record shape (`=~ "outcome"`).
- [x] T021 Run `mix format`, `mix credo`, and Dialyzer; resolve any warnings introduced (unused aliases/vars from the deleted gate/execute block).
- [x] T022 Run the FULL `mix test` suite and fix ALL failures (not just this feature's), per the house testing rule; confirm SC-005 (≥1 test drives outcome-record stdout + seeded transcript with no live model) and SC-006 (malformed run distinguishable from `:ok`).

---

## Phase 8: Discovery tool-channel migration (SCOPE EXPANSION)

**Purpose**: Added after implementation began. The spec's clean-cutover assumption was
false: the deterministic discovery agent (the substrate's default reference agent) still
emitted `{"actions"}` and never touched the rail, so a pure cutover would break it.
Decision (user, in-session): migrate discovery onto the broker tool-call channel so the
cutover is genuinely clean — discovery is a stubbed LLM agent whose "model" was never
wired up (there was no model when it was written). This retires the actions protocol
everywhere, keeping master green.

- [x] T023 Add `execute_tool/2` to `lib/agent_os/connector/kv_append.ex` (mirrors `store_append`): appends `%{"digest" => value}` to `roster_trust` inline and returns a synthetic success the rail records.
- [x] T024 Rewrite `agents/discovery/main.py`: build chat messages from the input items and call the broker over the UDS; print a terminal outcome record; drop `build_actions`/`Action`. Update `agents/discovery/models.py` (unchanged `DiscoveryInput`).
- [x] T025 Add a deterministic model stub + UDS harness to `test/test_helper.exs`: `discovery_provider_fn/0` (turns items into `kv_append` tool calls with the old high-signal/adversarial reasoning, terminates the loop on tool results) and `start_broker_uds!/1` (real broker + listener + stub over a temp socket in an ownable dir). Also start `action_transcript` in `start_mounts!`.
- [x] T026 Migrate the discovery-driven `run_supervisor_test.exs` cases (happy path, ungranted-drop) onto the UDS harness; rewrite the breach case to seed the ledger; remove the pure spend-charging blocks (coverage moved to `spend_ledger_test`/`inference_broker_test`).
- [x] T027 Swap `scheduler_test.exs` echo stubs to an outcome record; reconcile `agents/discovery/test_main.py` (pytest) to the new `build_messages`/outcome-record behavior.

**Checkpoint**: One protocol everywhere; full `mix test` green (352 passed, 0 failures); discovery pytest green (5 passed).

---

## Dependencies & Execution Order

- **Phase 1 (T001)** → baseline.
- **Phase 2 (T002–T004)** blocks everything; T003 depends on T002 (RED first), T004 independent.
- **US1 (T005–T010)** is the MVP and the first mutation of `execute_run/5`.
- **US2 (T011–T012)** depends on US1 (edits the same rewritten branch).
- **US3 (T013–T015)** depends on US1/US2 (breach branch shares the transcript read).
- **US4 (T016–T017)** depends on US1 (parked tally from the same transcript read); independent of US3.
- **Phase 7 (T018–T022)**: T018–T020 are `[P]` (different files) and can run once US1–US4 land; T021–T022 run last.

## Parallel Opportunities

- T002 (OutcomeRecord test) and T004 (run-token seam) — different files, parallel.
- T018, T019, T020 — three different test/fixture files, parallel.
- Within a story, RED test tasks touch the single new test file and are written together but assert independently.

## Implementation Strategy

- **MVP = Phase 1 + Phase 2 + US1 (Phase 3).** That alone flips real generated runs from
  100% misclassified to correctly recorded (SC-001) and is independently demoable.
- **US2 lands immediately after** (also P1) to close the double-execution hazard before
  anything ships.
- **US3 and US4 (P2)** harden spend/breach and approval accounting on top of the corrected
  read path.
- **Polish** retires the dead contract from existing suites and proves the whole tree green.

## Task Count

- Total: **22 tasks**
- Setup: 1 · Foundational: 3 · US1: 6 · US2: 2 · US3: 3 · US4: 2 · Polish: 5
