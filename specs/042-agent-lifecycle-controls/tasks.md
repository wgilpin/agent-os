---
description: "Task list for Agent Lifecycle Controls (042)"
---

# Tasks: Agent Lifecycle Controls

**Input**: Design documents from `/specs/042-agent-lifecycle-controls/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/agent-lifecycle.md

**Tests**: Backend logic is built test-first (Constitution III). The LiveView is NOT unit-tested
(Constitution III forbids frontend unit tests; no LiveView test harness exists) — it is verified by
the `quickstart.md` manual walkthrough.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1 (Pause/Resume), US2 (Delete), US3 (Spend cap), US4 (Schedule)

## Path Conventions

Elixir/OTP control plane: backend under `lib/agent_os/`, web under `lib/agent_os_web/`, tests under
`test/agent_os/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: No new project scaffolding needed; establish the new files.

- [X] T001 Create the lifecycle seam module skeleton `AgentOS.AgentLifecycle` in `lib/agent_os/agent_lifecycle.ex` with `@moduledoc` and function stubs (`pause/1`, `resume/1`, `delete/1`, `update_spend_cap/2`, `update_schedule/2`) each raising `not_implemented`, plus `@spec`s per `contracts/agent-lifecycle.md`.
- [X] T002 Create the test file `test/agent_os/agent_lifecycle_test.exs` with `use ExUnit.Case, async: false` and a hermetic `setup` that starts `AgentOS.StateStoreRegistry` and temp-dir StateStores for `deployments`, `spend_ledger`, `provenance`, `conformance`, `judge_results`, `security_review_results`, `pending_approvals` (mirror the pattern in `test/test_helper.exs` `start_mounts!/2` and `deployment_registry_test.exs`).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared substrate primitives that multiple user stories depend on: registry writers and
TriggerArming timer-ref tracking. **No user story can be completed until this phase is done.**

**⚠️ CRITICAL**: These change shared state shapes; complete and keep the suite green first.

### DeploymentRegistry primitives (sole writer to "deployments")

- [X] T003 [P] Add tests to `test/agent_os/deployment_registry_test.exs`: `mark_active/1` flips `active: true` while preserving `deployed_at`/`provenance`/`manifest_path`; `mark_active/1` on an unknown agent warns and no-ops; `delete/1` removes the record (`get/1` → nil); `delete/1` on an unknown agent warns and no-ops.
- [X] T004 Implement `mark_active/1` and `delete/1` in `lib/agent_os/deployment_registry.ex` (mirror `mark_inactive/1`; `delete/1` uses `StateStore.apply_action("deployments", {:delete_in, [agent_name]})`); update the moduledoc "production write sites" list to include the `AgentLifecycle` seam. Run the file's tests green (T003).

### TriggerArming: timer-ref tracking, disarm, rearm

- [X] T005 [P] Add tests to `test/agent_os/trigger_arming_test.exs`: `disarm/1` cancels the armed timer(s) for an agent (assert the ref returned by the injected `schedule_fn` is passed to an injectable cancel fn / no re-fire); `rearm/1` cancels the old time and arms the current manifest time (change the manifest between arm and rearm, assert a `{:scheduled, {:fire, agent, new_at}, _}`); a stale `{:fire, agent, at}` delivered after `disarm/1` does NOT re-arm (`armed[agent][at]` absent → dropped); confirm existing "fire re-checks registry" and boot-arming tests stay green with the new `%{agent => %{at => ref}}` shape.
- [X] T006 Refactor `lib/agent_os/trigger_arming.ex`: change `armed` from `%{agent => [at]}` to `%{agent => %{at => timer_ref}}`; capture the ref returned by `schedule_fn` in `arm_one`; add an injectable `:cancel_fn` (default `&Process.cancel_timer/1`) to `init`; add `disarm/1` and `rearm/1` GenServer calls (`rearm` reloads the manifest via `DeploymentRegistry.get/1` → `manifest_path`, arms current `:time` triggers only if the record exists and is active); in `handle_info({:fire, agent, at}, …)` re-arm only if `armed[agent][at]` still exists (stale-fire guard). Keep fire execution registry-gated. Run T005 green.

**Checkpoint**: Registry can activate/delete; TriggerArming can disarm/rearm without leaking timers.

---

## Phase 3: User Story 1 - Pause and resume an agent (Priority: P1) 🎯 MVP

**Goal**: One-click reversible kill-switch on `/inventory`; paused survives restart; resume restores
without redeploy or startup fire.

**Independent Test**: Pause a deployed agent, confirm a message trigger is refused; restart → still
paused; resume → dispatch works again, `deployed_at`/provenance intact, no startup fire.

### Backend (test-first)

- [X] T007 [US1] Add tests to `test/agent_os/agent_lifecycle_test.exs`: `pause/1` marks the record inactive (`deployed_and_active?` → false) and errors `{:error, :not_deployed}` for an agent with no record; `resume/1` flips the record active preserving `deployed_at`/`provenance`, errors `{:error, :not_deployed}` when no record and `{:error, :manifest_missing}` when the manifest file is gone; `resume/1` does NOT fire a startup trigger.
- [X] T008 [US1] Implement `AgentLifecycle.pause/1` (delegates to `DeploymentRegistry.mark_inactive/1`, mapping unknown-agent to `{:error, :not_deployed}`) and `resume/1` (`DeploymentRegistry.mark_active/1` guarded by record + manifest-file presence, then `TriggerArming.rearm/1`; never fires startup) in `lib/agent_os/agent_lifecycle.ex`. Run T007 green.

### UI (manual-walkthrough, no unit test)

- [X] T009 [US1] In `lib/agent_os_web/live/inventory_live.ex` add a **Pause** button (`phx-click="pause"` `phx-value-agent`, shown when deployed & active) and a **Resume** button (shown when record exists & `active: false`) in the roster panel; ensure the Paused badge state (`deployment_status_label`/`_class` for `active: false`) is visually distinct from never-deployed (already present — verify copy via `AgentOSWeb.HumanText`).
- [X] T010 [US1] Add `handle_event("pause", …)` and `handle_event("resume", …)` to `inventory_live.ex`: call `AgentOS.AgentLifecycle`, re-run `assign_agents_data/1` + `assign(last_updated: …)`, `put_flash(:error, …)` on `{:error, reason}` (humanized), and broadcast an `AgentOS.Pipeline.ProgressEvent` on `ProgressEvent.all_topic()` so other sessions refresh.

**Checkpoint**: Pause/Resume fully functional; MVP demoable.

---

## Phase 4: User Story 2 - Delete an agent completely (Priority: P2)

**Goal**: Permanent, confirmed removal of an agent and all per-agent state, preserving global history.

**Independent Test**: Delete a scratch agent → row, files, and per-agent state all gone; restart →
no warnings referencing it.

### Backend (test-first)

- [X] T011 [US2] Add tests to `test/agent_os/agent_lifecycle_test.exs`: `delete/1` removes the deployment record, `rm_rf`s a temp `agents/<name>` dir and `rm`s a temp `manifests/<name>.md`, deletes the agent key from `spend_ledger`/`provenance`/`conformance`/`judge_results`/`security_review_results`, and sweeps `pending_approvals` entries matching the agent (recipient == name); it tolerates partially-missing files/keys (no raise) and is idempotent; it does NOT touch `data/run_log.md`. Use injectable base paths (see T012) so the test writes under temp dirs.
- [X] T012 [US2] Implement `AgentLifecycle.delete/1` in `lib/agent_os/agent_lifecycle.ex` in order: `DeploymentRegistry.delete/1` → `TriggerArming.disarm/1` → remove files (`File.rm_rf`/`File.rm`, logging+continuing on error) → `{:delete_in, [name]}` on the five per-agent stores → sweep matching `pending_approvals` (reuse the match filter from `inventory.ex:63-71`, delete each via `{:delete_in, [:approvals, ref]}`). Make the `agents/`/`manifests/` base dirs injectable (module attribute or opts) for hermetic tests; leave `data/run_log.md` untouched (documented). Always returns `:ok`. Run T011 green.

### UI (manual-walkthrough, no unit test)

- [X] T013 [US2] In `inventory_live.ex` add a **Delete** button (always shown) with `data-confirm` spelling out that the agent's code, manifest, and runtime state are removed permanently; add `handle_event("delete", …)` that calls `AgentOS.AgentLifecycle.delete/1`, re-runs `assign_agents_data/1`, flashes on error, and broadcasts a `ProgressEvent` for cross-session refresh.

**Checkpoint**: Delete works end-to-end alongside Pause/Resume.

---

## Phase 5: User Story 3 - Edit an agent's spend cap (Priority: P3)

**Goal**: Change the daily spend cap in dollars from `/inventory`, effective next spend evaluation.

**Independent Test**: Set cap to a new dollar value → manifest shows it in micro-dollars → gate
enforces it next run; invalid input rejected with no change; accumulated spend preserved.

### Backend (test-first)

- [X] T014 [P] [US3] Add tests to `test/agent_os/agent_lifecycle_test.exs`: `update_spend_cap/2` writes `round(dollars * 1_000_000)` to `spend.cap` in a temp manifest and round-trips via `Manifest.load`; rejects `0`, negatives, and non-numeric with `{:error, :invalid_cap}` and no file change; leaves the `spend_ledger` entry untouched.
- [X] T015 [US3] Implement `AgentLifecycle.update_spend_cap/2` in `lib/agent_os/agent_lifecycle.ex`: validate `dollars > 0` numeric; `Manifest.load` → `put_in(manifest.spend.cap, round(dollars * 1_000_000))` → `Manifest.Projection.write/2`. Return typed errors on invalid input or load/write failure. Run T014 green.

### UI (manual-walkthrough, no unit test)

- [X] T016 [US3] In `inventory_live.ex` add a per-agent edit panel toggled via a `phx-click` assign (no JS) containing a number input for the spend cap in dollars (`> 0`); wire the submit into the shared `update_settings` handler (T019).

---

## Phase 6: User Story 4 - Edit an agent's schedule (Priority: P3)

**Goal**: Change the HH:MM of existing daily time triggers from `/inventory`, effective without
restart (old time stops, new time fires).

**Independent Test**: Change a trigger time to minutes ahead → exactly one fire at the new time, none
at the old; invalid time rejected with no change; no time triggers → no schedule fields.

### Backend (test-first)

- [X] T017 [P] [US4] Add tests to `test/agent_os/agent_lifecycle_test.exs`: `update_schedule/2` rewrites the `at` of matching `%{type: :time}` triggers in a temp manifest (other triggers untouched) and round-trips via `Manifest.load`; rejects an invalid `new_at` (`25:00`, `9:99`, non-`HH:MM`) with `{:error, {:invalid_time, _}}` and no file change; confirm it calls `TriggerArming.rearm/1` (inject/observe via a named TriggerArming test process or assert the manifest side effect + a rearm call through a seam).
- [X] T018 [US4] Implement `AgentLifecycle.update_schedule/2` in `lib/agent_os/agent_lifecycle.ex`: validate each `new_at` as `HH:MM` (00:00–23:59); rewrite matching time triggers; `Manifest.Projection.write/2`; then `TriggerArming.rearm/1`. Reject the whole edit on any invalid time (no write). Run T017 green.

### UI (manual-walkthrough, no unit test)

- [X] T019 [US4] In `inventory_live.ex` extend the edit panel with one HH:MM input per existing `%{type: :time}` trigger (none shown if the agent has no time triggers); add the `handle_event("update_settings", …)` handler that calls `update_spend_cap/2` and `update_schedule/2` via `AgentOS.AgentLifecycle`, re-runs `assign_agents_data/1`, flashes on error, and broadcasts a `ProgressEvent`. Add a `handle_event` to toggle the edit panel open/closed via assign.

---

## Phase 6b: Scope extension — full trigger editing (US4 revised)

**Purpose**: User feedback after trying the UI — agents with `triggers: []` or startup-only had a
dead schedule surface. Replaces "edit existing time values only" with full add/edit/remove/retype
of the trigger list (spec.md US4 + FR-010 amended accordingly).

- [X] T023 [US4] Generalize the seam: replace `AgentLifecycle.update_schedule/3` with `update_triggers/3` in `lib/agent_os/agent_lifecycle.ex` — accepts the full desired trigger list (atom- or string-keyed), validates atomically (types exactly startup/time/event/message; time needs valid HH:MM; event needs non-empty name; duplicates rejected; empty list allowed), rewrites the manifest via `Manifest.Projection.write/2`, then `TriggerArming.rearm/1`. Document that an edit never fires startup.
- [X] T024 [P] [US4] Extend `test/agent_os/agent_lifecycle_test.exs` with the `update_triggers/3` matrix: per-type round-trip (string- and atom-keyed), time-`at` change re-arms new time only, retype time→message cancels the timer, add-time-to-startup-only arms immediately, startup kept on edit does NOT fire, empty list succeeds, invalid time/blank event name/unknown type/duplicates each reject atomically with no file change.
- [X] T025 [P] [US4] Add a `TriggerArming` test: `rearm/1` after the manifest's time trigger is retyped away cancels the armed timer and arms nothing (`test/agent_os/trigger_arming_test.exs`).
- [X] T026 [US4] Rework the `inventory_live.ex` edit panel into a draft-based trigger editor (no JS): `@trigger_draft`/`@cap_draft` assigns seeded on `toggle_edit`, kept in sync via a form-level `phx-change="draft_change"`, per-row type `<select>` + type-appropriate field (`at` for time, `name` for event), per-row Remove and an Add-trigger button (`phx-click` events mutating the draft), submit sends everything through `update_settings` → `update_spend_cap/2` + `update_triggers/2`. Empty-list hint text; new `error_text` copy for the new error reasons; styles in `priv/static/app.css`.
- [X] T027 [US4] Amend spec artifacts for the widened scope: `spec.md` (US4 story + scenarios, FR-010, Edge Cases, Key Entities, SC-004, Assumptions — drop all "adding/removing triggers is out of scope" language), `contracts/agent-lifecycle.md` (`update_triggers` contract), `data-model.md` (trigger validation rules), `quickstart.md` (trigger-type conversion walkthrough step: startup → time two minutes ahead → fires; remove → silent).

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T020 Run `mix format` and ensure `mix compile --warnings-as-errors` is clean across all touched files.
- [X] T021 Run the full `mix test` suite; fix ALL failures encountered, not just feature-related ones (global rule).
- [X] T022 Execute the `quickstart.md` manual-walkthrough checklist mentally against the implemented UI to confirm each FR/SC has a corresponding button/handler/state (documentation-level verification; do not start the Phoenix server).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: depends on Setup; **blocks all user stories** (shared registry +
  TriggerArming primitives).
- **US1 (Phase 3)**: depends on Foundational (needs `mark_active`, `rearm`).
- **US2 (Phase 4)**: depends on Foundational (needs `delete`, `disarm`).
- **US3 (Phase 5)** and **US4 (Phase 6)**: depend on Foundational; US4 needs `rearm`. US3 and US4
  share the edit panel + `update_settings` handler (T016/T019 coordinate on the same file).
- **Polish (Phase 7)**: after all stories.

### Within Each User Story

- Backend tests written first and failing, then implementation to green (Constitution III).
- UI tasks follow their story's backend (the view calls the tested seam).

### Parallel Opportunities

- T003 and T005 (foundational tests in different files) can run in parallel.
- Backend test tasks T014 and T017 are independent additions to the lifecycle test file (mark [P] but
  serialize the actual file writes if edited concurrently).
- Once Foundational completes, US1 and US2 backends are independent; US3/US4 share the UI edit panel.

---

## Implementation Strategy

### MVP First (User Story 1)

1. Phase 1 Setup → Phase 2 Foundational (keep suite green) → Phase 3 US1 (Pause/Resume).
2. STOP and validate US1 independently (manual walkthrough sections 1).

### Incremental Delivery

1. Foundation ready → US1 (MVP) → US2 (Delete) → US3 (Spend cap) → US4 (Schedule).
2. Each story adds value without breaking the previous. Run `mix test` green after each.

---

## Notes

- All lifecycle mutations flow through `AgentOS.AgentLifecycle`; the LiveView holds no business logic.
- No inline JS anywhere (global rule); edit-panel toggle is a `phx-click` assign.
- The registry stays the sole writer to `"deployments"` (Constitution IX).
- Do not commit; leave all changes in the working tree.
