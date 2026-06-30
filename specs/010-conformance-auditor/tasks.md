# Tasks: Conformance Auditor

**Input**: Design documents from `specs/010-conformance-auditor/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: INCLUDED — the constitution mandates test-first for backend logic (Principle III). The
pure `audit/2`, the run-record parser, and the alert decision are built red→green. The `Scheduler`
GenServer and the inventory render string are covered by integration assertions, not unit tests.

**Organization**: by user story. MVP = User Story 1 (the trust flag — the load-bearing leg).

## Path Conventions

Single Elixir project: `lib/agent_os/`, `test/agent_os/`. Paths are repo-relative.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Configuration the rest of the feature reads.

- [ ] T001 Add conformance defaults to `config/config.exs`: `conformance_path` (`data/conformance.term`), `admin_alerts_path` (`data/admin_alerts.md`), `audit_run_hour`, and auditor defaults `window: 20`, `quiet_streak: 3`, `denied_threshold: 3`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared types, the run-log parser, persistence wiring, the orchestration/alert/render
machinery — everything both stories need before any flag can be raised. **No flag-detection logic
yet** (that is story-specific); `audit/2` here only resolves window + `clean`/`insufficient_data`.

⚠️ MUST complete before US1/US2.

- [ ] T002 [P] Create `RunRecord` struct + `@type` in `lib/agent_os/conformance_auditor/run_record.ex` (fields per data-model.md).
- [ ] T003 [P] Create `Flag` struct + `@type` + severity-ordering helper (`:health < :count < :tripwire`) in `lib/agent_os/conformance_auditor/flag.ex`.
- [ ] T004 [P] Create `Verdict` struct + `@type` (`:clean | :flagged | :insufficient_data`) in `lib/agent_os/conformance_auditor/verdict.ex`.
- [ ] T005 [P] Write tests for `RunLog.read_records/2` in `test/agent_os/run_log_test.exs`: parses multiple records, excludes `digest:` lines, returns last N in chronological order, and skips a malformed line **with a `Logger.warning`** (assert via `ExUnit.CaptureLog`).
- [ ] T006 Implement `RunLog.read_records/2` in `lib/agent_os/run_log.ex` (multi-record parser; leaves existing `Inventory.parse_last_run/1` untouched).
- [ ] T007 Write tests for the `audit/2` skeleton in `test/agent_os/conformance_auditor_test.exs`: empty/short trace ⇒ `:insufficient_data`; a sufficient clean trace ⇒ `:clean` with `flags: []`; window selection keeps the last N records.
- [ ] T008 Implement the `audit/2` skeleton in `lib/agent_os/conformance_auditor.ex`: window selection, `:insufficient_data` vs `:clean`, returns a `Verdict` with `[]` flags and `computed_at` from `opts[:now]` (no wall-clock in any threshold).
- [ ] T009 Wire the `"conformance"` single-writer `StateStore` (initial `%{}`, keyed by agent name) into the supervision tree in `lib/agent_os/application.ex` (under `:autostart`); verdicts persisted with the existing `{:put, agent, verdict}` action — no StateStore change.
- [ ] T010 [P] Write tests for the admin-alert sink in `test/agent_os/conformance_auditor/alert_test.exs`: `Alert.emit/3` appends one line to the configured `admin_alerts.md` and **never** writes `data/run_log.md` (assert run-log untouched); logs via `Logger`.
- [ ] T011 Implement `ConformanceAuditor.Alert.emit/3` in `lib/agent_os/conformance_auditor/alert.ex` (Logger + append to `admin_alerts.md`; notification-only; path overridable via opts).
- [ ] T012 Write tests for `run_pass/1` in `test/agent_os/conformance_auditor_test.exs`: it reads records, computes a verdict, persists it to `"conformance"`, and emits an alert **only** for newly-raised/escalated flags vs the previously persisted verdict (exactly-once — SC-008).
- [ ] T013 Implement `run_pass/1` in `lib/agent_os/conformance_auditor.ex`: resolve agent name + manifest purpose, `read_records`, load previous verdict, `audit/2`, persist via `{:put, agent, verdict}`, escalate-compare and `Alert.emit/3` per new/escalated flag. MUST NOT write the run-log or touch the gate/effector.
- [ ] T014 [P] Write tests for the inventory conformance block in `test/agent_os/inventory_test.exs`: a persisted `:clean` verdict renders `CONFORMANCE: clean`; `:flagged` renders a line per flag with its `[trust]`/`[health]` axis; no stored verdict renders `insufficient data`.
- [ ] T015 Implement the conformance provenance block in `lib/agent_os/inventory.ex`: read `StateStore.snapshot("conformance")[agent]` and render per contracts/inventory-render.md (reads the **persisted** verdict; never recomputes).

**Checkpoint**: structs, parser, store, orchestration, alert, and a generic render exist; `audit/2`
returns only `clean`/`insufficient_data`. Ready for flag-detection slices.

---

## Phase 3: User Story 1 — Reaching for what it wasn't cleared for (Priority: P1) 🎯 MVP

**Goal**: Raise the **trust** flags (Leg 2) — the gate-breach tripwire and the denied-approval count —
and surface them in the inventory and as an admin alert.

**Independent test**: Feed a trace with a single gate-breach record ⇒ trust flag; a trace with ≥3
human-denied approval-required actions ⇒ trust flag; ≤2 denials ⇒ none; verified from fixtures.

- [ ] T016 [US1] Write tests for the gate-breach tripwire in `test/agent_os/conformance_auditor_test.exs`: a single record with `breached_count > 0` **or** non-empty `gate_reasons` ⇒ `:gate_breach` flag (severity `:tripwire`); a clean trace ⇒ none.
- [ ] T017 [US1] Write tests for denied-approval and non-redundancy in `test/agent_os/conformance_auditor_test.exs`: ≥3 `approval-resume` records noted `denied` in window ⇒ `:denied_approval` flag; 1–2 ⇒ none; `rejected_count` is **never** counted (a trace with many `rejected_count` but no denials ⇒ no flag — FR-003); and a trace carrying recipient/method/spend anomalies but no breach/denial/omission ⇒ **no flag** (SC-006 — the auditor never re-reports what the gate enforces per action).
- [ ] T018 [US1] Implement Leg 2 detection in `audit/2` in `lib/agent_os/conformance_auditor.ex`: `:gate_breach` (tripwire) and `:denied_approval` (count ≥ `denied_threshold`) detectors; set `status: :flagged` when present.
- [ ] T019 [US1] Write a test that the inventory render shows the trust flags and that `run_pass/1` emits exactly one admin alert when a trust flag is newly raised, in `test/agent_os/conformance_auditor_test.exs` (alert assertion) and `test/agent_os/inventory_test.exs` (render assertion).
- [ ] T020 [US1] Write the FLAG-ONLY test for the trust path in `test/agent_os/conformance_auditor_test.exs`: `audit/2` returns only a `Verdict` of flags — there is no return value, opt, or branch that yields a pass/approval/deploy-gate (US1 acceptance scenario 4).

**Checkpoint**: MVP — a human sees a trust flag in the inventory and an admin alert, computed only
from the trace, gating nothing.

---

## Phase 4: User Story 2 — Gone quiet or sick (Priority: P2)

**Goal**: Raise the **health** flags (Leg 1) — quiet (no-action streak) and sick (alert / rising shed).

**Independent test**: A trace with a 3-run no-action streak ⇒ quiet flag; a trace with a `status=alert`
run or a strictly-rising `items_dropped` share in the latest record ⇒ sick flag; a normal productive
trace ⇒ none.

- [ ] T021 [US2] Write tests for the quiet flag in `test/agent_os/conformance_auditor_test.exs`: a trailing streak of ≥3 `actions=0` runs ⇒ `:quiet` flag; a recent productive run clears the streak ⇒ none.
- [ ] T022 [US2] Write tests for the sick flag in `test/agent_os/conformance_auditor_test.exs`: a `status=alert` run in window ⇒ `:sick`; the latest record dropping a strictly greater input share than the previous record (with `items_dropped > 0`) ⇒ `:sick`; an equal or falling share ⇒ none; a normal trace ⇒ none.
- [ ] T023 [US2] Implement Leg 1 detection in `audit/2` in `lib/agent_os/conformance_auditor.ex`: `:quiet` (trailing streak ≥ `quiet_streak`) and `:sick` (alert / rising shed) detectors.
- [ ] T024 [US2] Write a totality test in `test/agent_os/conformance_auditor_test.exs`: a trace that is simultaneously quiet AND has a gate-breach lists **both** flags (no suppression — FR-007); and add an `inventory_test.exs` assertion that health flags render with the `[health]` axis.

**Checkpoint**: both health and trust flags work and co-exist; every applicable flag is shown.

---

## Phase 5: User Story 3 — A verdict trusted because it is computed only from the record (Priority: P3)

**Goal**: Lock in the cross-cutting properties that make every verdict trustworthy.

**Independent test**: the same trace yields the same verdict regardless of runtime state or agent
self-assertion; no verdict path can emit a pass.

- [ ] T025 [US3] Write a determinism test in `test/agent_os/conformance_auditor_test.exs`: `audit/2` on a fixed trace + opts returns an identical `Verdict` across repeated calls and differing global/runtime state (SC-004).
- [ ] T026 [US3] Write a trace-sourced test in `test/agent_os/conformance_auditor_test.exs`: the verdict depends only on `records` + `purpose` and is unaffected by any agent self-assertion or agent-supplied content.
- [ ] T027 [US3] Write the comprehensive FLAG-ONLY invariant test in `test/agent_os/conformance_auditor_test.exs`: exercise breach, denial, omission, and clean traces and assert no pass/approval/deploy-gate outcome is ever produced (SC-007). Add a guard/typespec hardening in `lib/agent_os/conformance_auditor.ex` only if the test reveals a gap.

**Checkpoint**: all spec properties (FAITHFUL-to-trace, deterministic, flag-only, non-redundant) are
test-enforced.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Scheduling, edge cases, and quality gates.

- [ ] T028 Implement `ConformanceAuditor.Scheduler` (daily self-rescheduling GenServer mirroring `AgentOS.Scheduler`, `:run_fn` injectable) in `lib/agent_os/conformance_auditor/scheduler.ex`.
- [ ] T029 Add the `ConformanceAuditor.Scheduler` child to the supervision tree in `lib/agent_os/application.ex` (under `:autostart`, alongside `Scheduler`).
- [ ] T030 [P] Write edge-case tests in `test/agent_os/conformance_auditor_test.exs`: no-history agent ⇒ `:insufficient_data` (not an error, no spurious flag); a short trace still evaluates the gate-breach tripwire while rate/streak signals report insufficient data (spec Edge Cases).
- [ ] T031 [P] Run the quickstart walkthrough (`specs/010-conformance-auditor/quickstart.md`) end-to-end in `iex`; confirm the inventory block and an `admin_alerts.md` line appear.
- [ ] T032 [P] Quality gates: `mix format --check-formatted`, `mix credo`, `mix dialyzer`, and full `mix test` all clean (Principle Quality Gates).

---

## Dependencies & Execution Order

- **Setup (T001)** → **Foundational (T002–T015)** → **US1 (T016–T020)** → **US2 (T021–T024)** → **US3 (T025–T027)** → **Polish (T028–T032)**.
- **US1 is the MVP** and the priority slice. US2 depends only on Foundational (not on US1) and could
  follow it directly; US3's invariant tests are strongest once both legs (US1+US2) exist.
- Within Foundational: T002/T003/T004 are independent structs; T005→T006 (parser); T007→T008 (skeleton);
  T009 (store) before T012/T013 (run_pass); T010→T011 (alert) before T013; T014→T015 (render).
- Story phases edit the shared `lib/agent_os/conformance_auditor.ex` `audit/2`, so the impl tasks
  (T018, T023) are **not** parallel with each other.

## Parallel Opportunities

- **Foundational structs**: T002, T003, T004 together ([P] — three different files).
- **Test-authoring across different files**: T005 (`run_log_test`), T010 (`alert_test`), T014
  (`inventory_test`) can be written in parallel.
- **Polish**: T030, T031, T032 ([P]).
- Tasks targeting `conformance_auditor_test.exs` (T007, T012, T016–T027, T030) share one file and are
  **not** mutually parallel.

## Independent Test Criteria (per story)

- **US1**: single gate-breach ⇒ trust flag; ≥3 human denials ⇒ trust flag; ≤2 ⇒ none; `rejected_count`
  ignored; flag-only.
- **US2**: 3-run no-action streak ⇒ quiet; alert/rising-shed ⇒ sick; productive ⇒ none; co-exists with trust.
- **US3**: identical verdict for identical trace regardless of runtime/agent-assertion; no pass path.

## Implementation Strategy

Ship **US1 as the MVP** (Foundational + Phase 3): the load-bearing trust flag visible in the inventory
with an admin alert. Add US2 (health) and US3 (property hardening) incrementally. Defer the LLM
semantic-drift leg to 04-05+ (out of scope here).

**Total tasks**: 32 — Setup 1, Foundational 14, US1 5, US2 4, US3 3, Polish 5.
