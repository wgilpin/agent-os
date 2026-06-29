# Tasks: Event-, Message-, and Approval-as-Event Triggers

**Input**: Design documents from `specs/007-event-message-triggers/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: INCLUDED. The control plane is TDD-backend (Constitution III): gateway dispatch, allowlist
default-deny, approval-resume at-most-once, and provenance are backend logic, built test-first
(red → green). The one Python field-read is an integration change and is NOT unit-tested (per III).

**Organization**: Tasks are grouped by user story. US1 (event) is the MVP; US2 (message) and US3
(approval) each build on the shared foundation and are independently testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1 / US2 / US3 (setup, foundational, polish carry no story label)
- All paths are repo-relative; the project is single-project Elixir (`lib/agent_os/`, `test/agent_os/`).

## Reuse map (what already exists — do NOT rebuild)

- `Manifest` already parses `{:event, name}` and `{:message}` triggers — used as the allowlist.
- `Gate.partition_batch/4` already produces `parked` (`needs_approval`) actions.
- `RunWorker` already persists parked actions to the `pending_approvals` store as `%{ref, action, grant}`.
- `pending_approvals` is already a single-writer `StateStore` in the supervision tree.
- `RunSupervisor.start_run/1` already accepts a `trigger:` opt; `RunWorker`/`RunLog` already stamp `trigger=`.
- `Effector.act/1` already executes a `%{action, grant}` at the post-gate chokepoint.
- `external_send` is already `requires_approval?: true` (so parked actions exist today).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Demo data prep; no behavioural code.

- [x] T001 [P] Add an `event` trigger named `bookmark_saved` to `manifests/discovery.md` (data only, alongside the existing `time` + `message` triggers) so the event-trigger slice is demonstrable per quickstart.md.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The `TriggerGateway` skeleton, its supervision wiring, run-input threading, and provenance
formatting — shared by all user stories.

**⚠️ CRITICAL**: No user-story dispatch logic can be implemented until this phase is complete.

- [x] T002 Create `AgentOS.TriggerGateway` GenServer skeleton in `lib/agent_os/trigger_gateway.ex`: `@moduledoc`/`@doc`, `@type signal :: {:event, String.t(), term()} | {:message, String.t(), term()} | {:approval, :approve | :deny, String.t()}`, `start_link/1`, `init/1`, `submit/1` (cast → `submit_sync`), and `submit_sync/2` with DI opts (`:start_run_fn` default `&AgentOS.RunSupervisor.start_run/1`, `:effector_fn` default `&AgentOS.Effector.act/1`, `:manifests_fn` default loads the configured manifest(s), `:now`). Dispatch on signal variant to private stubs that log + return `{:rejected, :not_implemented}` for now. Typespecs on all public functions (Constitution V).
- [x] T003 Register `AgentOS.TriggerGateway` in the supervision tree in `lib/agent_os/application.ex` (autostart branch only; tests start it in isolation).
- [x] T004 Thread run input: `AgentOS.RunWorker.run_once/1` reads `Keyword.get(opts, :trigger_input)` and `build_payload/2` includes it as one optional JSON field (omit/`null` when absent so timer fires are unchanged), in `lib/agent_os/run_worker.ex`.
- [x] T005 [P] Read the optional `trigger_input` field from the stdin JSON in the Python workload `agents/discovery/main.py` (one field via `payload.get("trigger_input")`; no new agent logic, no model call; `ruff`/`mypy` clean).
- [x] T006 [P] Write FAILING provenance tests in `test/agent_os/run_log_test.exs`: a run-log entry with `trigger: "event:bookmark_saved"` round-trips append→parse with the name intact; `"message"` and `"approval-resume"` likewise.
- [x] T007 Format the extended `trigger=` provenance values (`event:<name>`, `message`, `approval-resume`) in `lib/agent_os/run_log.ex` (single-token provenance — no embedded whitespace; whitespace rejection is enforced upstream at the gateway, T009). Make T006 pass.

**Checkpoint**: Gateway boots and rejects everything; input + provenance plumbing is green. Story dispatch can begin.

---

## Phase 3: User Story 1 — Event-trigger fires a declared agent (Priority: P1) 🎯 MVP

**Goal**: A named event matched against the manifest allowlist fires exactly one run per matching agent, payload delivered as input; an unlisted event fires nothing.

**Independent Test**: Submit `{:event, "bookmark_saved", payload}` → exactly one `start_run` with `trigger: "event:bookmark_saved"` + payload; submit an unlisted event → zero runs, `{:fired, []}`.

- [x] T008 [US1] Write FAILING event-dispatch tests in `test/agent_os/trigger_gateway_test.exs` (inject `start_run_fn` to capture calls, `manifests_fn` to supply manifests): event matching a manifest `event` trigger → exactly one captured `start_run` with `trigger: "event:bookmark_saved"`, `trigger_input: payload`; unlisted event → zero captures, `{:fired, []}`; agent with no `event` trigger → unaffected; two identical events → two captures (one per admitted signal, never collapsed); a malformed event (empty `name`, or `name` containing whitespace) → zero captures, `{:rejected, :invalid_event_name}` (FR-010 / edge: malformed payload rejected at intake, G2).
- [x] T009 [US1] Implement `:event` dispatch in `lib/agent_os/trigger_gateway.ex`: load manifests via `manifests_fn`, select agents whose triggers contain `%{type: :event, name: ^name}`, reject an event `name` that is empty or contains whitespace at intake (`{:rejected, :invalid_event_name}`, single-token provenance, G2/I1); call `start_run_fn.(trigger: "event:" <> name, trigger_input: payload, agent: agent)` per match, return `{:fired, agents}`; default-deny with a distinct log when no agent matches (FR-002). Make T008 pass.

**Checkpoint**: US1 fully functional and independently testable (MVP).

---

## Phase 4: User Story 2 — Message-trigger wakes an agent (Priority: P2)

**Goal**: A message addressed to a message-triggered agent fires one run with the content as input; the operator is just another caller of `submit/1`, not a privileged path.

**Independent Test**: Submit `{:message, "discovery", content}` → one `start_run` `trigger: "message"` + content; submit to an agent without a `message` trigger → `{:rejected, :no_message_trigger}`, zero runs.

- [x] T010 [US2] Write FAILING message-dispatch tests in `test/agent_os/trigger_gateway_test.exs`: message to a message-triggered agent → one captured `start_run` with `trigger: "message"`, `trigger_input: content`; agent lacking a `message` trigger → `{:rejected, :no_message_trigger}`, zero captures; unknown agent → `{:rejected, :unknown_agent}`, zero captures.
- [x] T011 [US2] Implement `:message` dispatch in `lib/agent_os/trigger_gateway.ex`: resolve the named agent (reject `:unknown_agent` if absent from inventory), require a `%{type: :message}` trigger (else `:no_message_trigger`, default-deny, FR-004), else `start_run_fn.(trigger: "message", trigger_input: content, agent: agent)` → `{:fired, [agent]}`. Make T010 pass.

**Checkpoint**: US1 + US2 both independently functional.

---

## Phase 5: User Story 3 — Approval of a held action is an event-trigger (Priority: P2)

**Goal**: A gate-parked action is held visibly and released by — and only by — a matching approval (exactly that action, at most once); a denial drops it; the agent can never originate an approval.

**Independent Test**: With a parked `ref`, submit `{:approval, :approve, ref}` → exactly that `%{action, grant}` executes once via the injected effector and the ref is removed; submit `{:approval, :deny, ref}` → nothing executes, ref removed; duplicate approve → at most once.

- [x] T012 [US3] Add a generic atomic `{:delete_in, [key, subkey]}` action to the `StateStore` reducer in `lib/agent_os/state_store.ex` (new `handle_call({:apply, {:delete_in, path}}, …)` that deletes a nested key; agent-agnostic — NO `approval`/`ref` vocabulary in the kernel, Principle IX), plus an `@doc` line. This makes remove-before-execute race-free.
- [x] T013 [US3] Write FAILING approval-resume tests in `test/agent_os/trigger_gateway_test.exs` (inject `effector_fn`; start an isolated `pending_approvals` `StateStore` seeded with `%{ref => %{ref, action, grant}}`): parked `ref` + `:approve` → `effector_fn` called exactly once with the stored `%{action, grant}`, entry removed, `{:resolved, :approved}`; duplicate `:approve` → `effector_fn` called once total, second → `{:resolved, :unknown_ref}`; `:deny` → `effector_fn` not called, entry removed, `{:resolved, :denied}`; unknown `ref` (including an agent-invented ref — the closest testable proxy for US3 AS5 / FR-009, since the agent has no channel to the gateway) → `effector_fn` not called, `{:resolved, :unknown_ref}`; a held action stays unexecuted until an approval arrives (G1).
- [x] T014 [US3] Implement `:approval` dispatch in `lib/agent_os/trigger_gateway.ex`: snapshot `pending_approvals`; on a matching `ref`, REMOVE FIRST via `{:delete_in, [:approvals, ref]}` (T012), then on `:approve` call `effector_fn.(%{action: action, grant: grant})` and `RunLog.append` with `trigger: "approval-resume"` + `ref`; on `:deny` drop + log; unknown `ref` → logged no-op `{:resolved, :unknown_ref}` (FR-007/008/013, agent-cannot-originate by construction). Make T013 pass.
- [x] T015 [US3] Write FAILING inventory test in `test/agent_os/inventory_test.exs`: with the `pending_approvals` store seeded, the standing inventory render lists each pending entry (ref + short action summary, e.g. `external_send → owner-inbox`).
- [x] T016 [US3] Render the `pending_approvals` entries on the standing inventory in `lib/agent_os/inventory.ex` (read the persisted store; ref + action summary), without asking the agent (FR-012, Principle VIII). Make T015 pass.

**Checkpoint**: All three slices independently functional; held actions are legible and release only on approval.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T017 [P] Run the quickstart.md walkthrough in IEx (event fire, message fire, approve/deny a parked `external_send`); confirm run-log provenance and inventory pending list.
- [x] T018 [P] `mix format --check-formatted` + `mix credo` clean; Dialyzer clean across `trigger_gateway.ex`, `run_worker.ex`, `run_log.ex`, `inventory.ex`, `state_store.ex`, `application.ex`.
- [x] T019 [P] Run the full suite `mix test` — confirm no pre-existing test regressed (Constitution / global rule: fix all failing tests, not just new ones).
- [x] T020 Update `.planning/ROADMAP.md` and `.planning/STATE.md` to mark roadmap plan 03-05 complete (spec 007), leaving 03-06 (world-B) as the last remaining Phase 3 plan.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (T001)**: independent; can run anytime.
- **Foundational (T002–T007)**: T002 → T003; T004, T005, T006 independent of the gateway; T006 → T007. BLOCKS all stories (the gateway skeleton + input/provenance plumbing).
- **US1 (T008–T009)**: after Foundational. T008 → T009.
- **US2 (T010–T011)**: after Foundational. T010 → T011. Shares `trigger_gateway.ex`/`trigger_gateway_test.exs` with US1 → sequence after US1 (same-file, not parallel).
- **US3 (T012–T016)**: after Foundational. T012 → T013 → T014; T015 → T016. Shares the gateway file → sequence after US2.
- **Polish (T017–T020)**: after the desired stories are complete.

### Story independence

- US1 is a standalone MVP (event firing) — no dependency on US2/US3.
- US2 (message) reuses the same dispatch + input plumbing but is separately testable.
- US3 (approval) reuses the gateway intake + the existing parked store; separately testable with a seeded `pending_approvals` store, no need to run a real agent.

### Within each story

- Test task FIRST (must fail), then implementation (red → green). Models/state ops before services; service (gateway dispatch) before legibility (inventory).

### Parallel opportunities

- T001 ∥ T002 (data vs code).
- In Foundational: T004 (run_worker) ∥ T005 (python) ∥ T006 (run_log test) — different files.
- In Polish: T017 ∥ T018 ∥ T019 — independent checks.
- The three stories touch the **same** `trigger_gateway.ex` + `trigger_gateway_test.exs`, so US1/US2/US3 run **sequentially**, not in parallel, despite being independently testable.

---

## Parallel Example: Foundational

```bash
# After T002 (skeleton) + T003 (supervision), these touch different files:
Task T004: "Thread :trigger_input through RunWorker in lib/agent_os/run_worker.ex"
Task T005: "Read trigger_input field in agents/discovery/main.py"
Task T006: "Write failing run-log provenance tests in test/agent_os/run_log_test.exs"
```

---

## Implementation Strategy

### MVP first (US1 only)

1. T001 (Setup) → T002–T007 (Foundational) → T008–T009 (US1).
2. **STOP and VALIDATE**: an event fires exactly one run with its payload; an unlisted event fires nothing; provenance shows `event:<name>`.
3. Demo-ready MVP.

### Incremental delivery

1. Foundation ready → US1 (event) → validate → demo.
2. Add US2 (message) → validate → demo.
3. Add US3 (approval) → validate (approve/deny a parked `external_send`) → demo.
4. Polish: full suite green, formatters/Dialyzer clean, roadmap/state updated.

---

## Notes

- [P] = different files, no incomplete dependency. The gateway and its test file are shared across stories → those tasks are sequential.
- No live LLM, no network, no Docker in any test — `start_run_fn`/`effector_fn`/`manifests_fn`/`now` are injected (Constitution IV).
- The agent has no path to `TriggerGateway`; self-fire and self-approve are impossible by construction, not by a runtime check (FR-009/010).
- Commit after each task or logical group (per the project's git rule, the human triggers the commit).
