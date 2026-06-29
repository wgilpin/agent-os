# Tasks: Spend Metering and Real Kill-on-Breach

**Input**: Design documents from `specs/005-spend-metering/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: INCLUDED — this is a test-first backend (Constitution III: red → green → refactor) and
the plan's test strategy is explicit. Each story writes failing tests before implementation.

**Organization**: Tasks are grouped by user story so each is independently implementable and
testable. US1 and US2 both edit `lib/agent_os/run_worker.ex` (sequential on that file); US3 is
independent after Foundational and may proceed in parallel.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1 / US2 / US3 (maps to spec.md user stories)
- All paths are repository-relative; control-plane only (Elixir), no Python change.

## Constraints carried from plan (do NOT violate)

- **FR-011 / FR-013**: do NOT change `lib/agent_os/gate.ex` allow/deny/recipient/method logic,
  the connector cost model, or the meter location — the meter stays in `RunWorker` post-gate.
- **Constitution IV**: no Docker, no live LLM, no external service in any test. Costs come from
  the connector registry; the clock is injected via `:now`.
- **No new store / no new supervision-tree process**: `spend_ledger` is already started.

---

## Phase 1: Setup

**Purpose**: Establish a clean baseline so any regression is attributable.

- [x] T001 Confirm a green baseline before changes: run `mix format --check-formatted && mix credo && mix dialyzer && mix test` from repo root and record that it passes (fix or note any pre-existing failure per CLAUDE.md "fix all failing tests").

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The pure window-math helper shared by US1 (enforcement) and US3 (visibility). Defines the windowed-entry semantics once.

**⚠️ CRITICAL**: US1 and US3 both depend on `AgentOS.SpendLedger`; complete this phase first.

- [x] T002 Write failing pure tests in `test/agent_os/spend_ledger_test.exs` per [contracts/spend-ledger.md](./contracts/spend-ledger.md): `duration_seconds(:daily) == 86_400`; `rolled_over?/3` false within window (start + 1h), true exactly at boundary (start + 24h) and beyond; `current_entry/3` returns entry unchanged within window, returns `%{spent: 0, window_start: now}` at/after boundary, and zeroes spend when several windows elapsed (start + 3 days). No process, no I/O.
- [x] T003 Implement `AgentOS.SpendLedger` in `lib/agent_os/spend_ledger.ex` to pass T002: `@type entry :: %{spent: number(), window_start: DateTime.t()}`, `@type window :: :daily`, and pure functions `duration_seconds/1` (explicit `:daily` clause — loud failure on other values), `rolled_over?/3` (`DateTime.compare(now, DateTime.add(window_start, duration, :second)) != :lt`), `current_entry/3` (reset to `%{spent: 0, window_start: now}` when rolled over, else unchanged). `@doc`/`@moduledoc` on every function; Dialyzer clean.

**Checkpoint**: `SpendLedger` complete and unit-tested — US1 and US3 can begin.

---

## Phase 3: User Story 1 - Spend is capped per window and resets at the boundary (Priority: P1) 🎯 MVP

**Goal**: Make `window_start` load-bearing — `RunWorker` resets spend at the window boundary before the gate check and feeds the windowed `spent` to the gate, so the cap is per-window, not lifetime.

**Independent Test**: With a small cap, an injected `:now`, and the host `agent_cmd` override: a run whose summed cost lands at the cap executes (ledger `spent == cap`); after advancing `:now` past the boundary, an agent previously at the cap can act again (spend reset to zero); within a window, spend keeps accumulating (no premature reset).

### Tests for User Story 1 ⚠️ (write first, ensure they FAIL)

- [x] T004 [US1] Add failing windowed-cap tests in `test/agent_os/run_supervisor_test.exs` (per [contracts/run-worker.md](./contracts/run-worker.md), driving `RunWorker.run_once/1` with `agent_cmd` host override, explicit `items`/actions, small cap, injected `:now`): (a) actions summing to exactly the cap execute and `spend_ledger[agent].spent == cap`; (b) pre-seed `%{spent: cap, window_start: now - 25h}`, then the same action that was capped is permitted and the ledger shows a reset window (`spent` reflects only the new run, `window_start ≈ now`); (c) within the window (`now = start + 1h`) spend accumulates against the existing window with no reset. Assert on ledger/execution effects, NOT on the breach return value (US2 changes that).

### Implementation for User Story 1

- [x] T005 [US1] Edit `lib/agent_os/run_worker.ex` (replacing the ledger read at ~L160-166): set `now = Keyword.get(opts, :now, DateTime.utc_now())`; read the `spend_ledger` snapshot and default a missing entry to `%{spent: 0, window_start: now}`; compute `entry = AgentOS.SpendLedger.current_entry(raw_entry, now, manifest.spend.window)`; if `entry != raw_entry` persist the reset via `StateStore.apply_action("spend_ledger", {:put, agent_name, entry})` BEFORE the gate check; pass `entry.spent` into `Gate.partition_batch(..., %{spent: entry.spent})`. The existing post-gate cost increment now builds on the windowed value. (depends on T003, T004)

**Checkpoint**: Windowed cap + reset fully functional and independently testable.

---

## Phase 4: User Story 2 - A breach fires the declared on_breach kill, distinct from a crash (Priority: P1)

**Goal**: Replace the hardcoded breach behaviour with dispatch on `manifest.spend.on_breach`; the `:kill` arm drops the whole batch (FR-012), returns a distinct intentional-stop signal, and the supervisor does not restart it — while a genuine crash/OOM still restarts once.

**Independent Test**: An over-cap run returns `{:killed, :spend_breach}`, executes nothing, and logs `status=killed failure_cause=spend_breach`. Via `RunSupervisor`: a worker returning `{:killed, :spend_breach}` is called exactly once with no Alerter; a worker returning `{:error, _}` then `:ok` is called twice (restart-once preserved); a persistently failing worker triggers the Alerter.

### Tests for User Story 2 ⚠️ (write first, ensure they FAIL)

- [x] T006 [US2] Add failing breach/supervision tests in `test/agent_os/run_supervisor_test.exs` (per [contracts/run-worker.md](./contracts/run-worker.md)): (a) an over-cap `RunWorker.run_once/1` returns `{:killed, :spend_breach}`, calls no Effector action / does not increment the ledger, and writes `status=killed failure_cause=spend_breach` to the run log; (b) `RunSupervisor.start_run(worker_fn: fn _ -> {:killed, :spend_breach} end)` → worker called once, `refute_receive` a second call, and no `status=alert` line; (c) keep/confirm the existing crash-once-retry and crash-twice-alert cases still pass with `{:error, _}`.
- [x] T007 [US2] Edit the breach branch of `lib/agent_os/run_worker.ex` (replacing the hardcoded kill at ~L174-196): introduce `defp dispatch_on_breach(:kill, ...)` that appends the existing `status=killed failure_cause=spend_breach` run-log line and returns `{:killed, :spend_breach}`; call it as `dispatch_on_breach(manifest.spend.on_breach, ...)` so the fired behaviour is the declared one (FR-004); widen `@spec run_once(keyword()) :: :ok | {:killed, :spend_breach} | {:error, any()}` and update the `@doc`/`@moduledoc`; add a `{:killed, _reason} -> :ok` clause to `run_and_raise/1` so the intentional kill is a normal Task exit. No Effector call and no ledger increment on the breach path (FR-012). (depends on T005, T006)
- [x] T008 [P] [US2] Edit `run_loop/2` in `lib/agent_os/run_supervisor.ex`: add a clause matching `{:killed, _reason} -> :ok` (terminal — no retry, no `Alerter.alert`), leaving the `:ok` success clause and the `{:error, reason}` retry-once-then-alert clause unchanged. (depends on T006)

**Checkpoint**: Breach fires the declared kill, is distinguishable from a crash, and the supervisor honours both — US1 + US2 work independently.

---

## Phase 5: User Story 3 - Current spend is visible per agent for the current window (Priority: P2)

**Goal**: The standing inventory reports `spent / cap / window` for the current window per agent, read from the persisted `spend_ledger` snapshot, without contacting the agent.

**Independent Test**: Seed the `spend_ledger` store; `Inventory.render(manifest_path: ..., now: ...)` output contains `SPEND: <spent> / <cap> per <window>`; after a rollover the same render shows `SPEND: 0 / <cap> per <window>`; an empty ledger shows zero; the render reads only the store + manifest (no agent invocation).

### Tests for User Story 3 ⚠️ (write first, ensure they FAIL)

- [x] T009 [P] [US3] Add failing spend-visibility tests in `test/agent_os/inventory_test.exs` (per [contracts/inventory-spend.md](./contracts/inventory-spend.md)): (a) seed `spend_ledger` with `%{agent => %{spent: 3, window_start: now}}` → render with `:now` contains `SPEND: 3 / 5 per daily`; (b) seed `%{spent: 5, window_start: now - 25h}` → render shows `SPEND: 0 / 5 per daily` (windowed reset applied for display); (c) empty ledger → `SPEND: 0 / 5 per daily`; (d) render reads only store + manifest (no port/agent contact), consistent with existing inventory tests.

### Implementation for User Story 3

- [x] T010 [US3] Edit `lib/agent_os/inventory.ex` (replacing the `SPEND CAP:` line at ~L89): set `now = Keyword.get(opts, :now, DateTime.utc_now())`; read the `spend_ledger` snapshot; default a missing agent entry to `%{spent: 0, window_start: now}`; compute `entry = AgentOS.SpendLedger.current_entry(raw_entry, now, manifest.spend.window)` (display only — do NOT persist); render `SPEND: #{entry.spent} / #{manifest.spend.cap} per #{manifest.spend.window}`. `@doc` updated; no agent contact. (depends on T003, T009)

**Checkpoint**: All three stories independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T011 Run `mix dialyzer` and confirm the widened `run_once/1` spec and `SpendLedger` typespecs are clean (Constitution V); fix any spec/typing gaps in `lib/agent_os/run_worker.ex`, `lib/agent_os/spend_ledger.ex`, `lib/agent_os/inventory.ex`.
- [x] T012 Run the full quality gate and validate scenarios: `mix format && mix credo && mix dialyzer && mix test`, then walk the five scenarios in [quickstart.md](./quickstart.md). Confirm NO pre-existing test regressed (CLAUDE.md "fix all failing tests").

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (T001)**: no dependencies.
- **Foundational (T002 → T003)**: after Setup. BLOCKS US1 and US3.
- **US1 (T004 → T005)**: after Foundational.
- **US2 (T006 → T007, T008)**: T007 after US1's T005 (same file, `run_worker.ex`); T008 independent of T007. Both after T006.
- **US3 (T009 → T010)**: after Foundational only — independent of US1/US2.
- **Polish (T011, T012)**: after all desired stories complete.

### Within each story

- Tests are written and FAIL before implementation (red → green).
- `SpendLedger` (foundational) before `RunWorker`/`Inventory` use it.
- `run_worker.ex` window-reset (T005) before its breach-branch refactor (T007).

### Parallel opportunities

- T008 (`run_supervisor.ex`) ∥ T007 (`run_worker.ex`) — different files, both gated on T006.
- US3 (T009, T010 — `inventory.ex` + `inventory_test.exs`) can run fully in parallel with US1/US2
  once T003 is done — no shared files.
- Test-writing tasks for different stories (T004 / T006 vs. T009) touch different test files and
  can be authored in parallel.

### Parallel example (after Foundational T003)

```bash
# Stream A (P1 enforcement, run_worker.ex — sequential):
T004 → T005 → T006 → T007
# Stream B (supervisor, different file — joins after T006):
T008
# Stream C (P2 visibility, inventory.ex — fully independent):
T009 → T010
```

---

## Implementation Strategy

### MVP first (US1)

1. T001 baseline → T002–T003 `SpendLedger` → T004–T005 windowed cap + reset.
2. **STOP and VALIDATE**: the cap is now per-window and resets at the boundary (quickstart
   scenarios 1 and 3). This alone fixes the "cap meaningless after the first period" defect.

### Incremental delivery

1. Foundation (`SpendLedger`) ready.
2. US1 → windowed cap + reset (MVP) → validate.
3. US2 → declared on_breach kill, distinct from crash, restart-exempt → validate.
4. US3 → per-agent spend visible on the inventory → validate.
5. Polish → Dialyzer + full gate + quickstart walkthrough.

## Notes

- [P] = different files, no dependency on an incomplete task.
- Each story is independently testable; US1's tests assert on ledger/execution effects (not the
  breach return value) so they survive US2's change to the breach return.
- Per CLAUDE.md: do not commit; leave changes in the working tree for the operator. Fix any
  pre-existing failing tests encountered, not just feature-related ones.
