# Feature Specification: Spend Metering and Real Kill-on-Breach

**Feature Branch**: `005-spend-metering`
**Created**: 2026-06-29
**Status**: Draft
**Input**: User description: "Spend metering and real kill-on-breach: spend is {cap, window, on_breach}, metered deterministically, visible per agent, and a breach triggers the declared kill. This is roadmap plan 03-04 of Agent OS (Phase 3, Manifest Enforcement / v2). It carves User Story 4 of specs/002-manifest-enforcement into its own feature (005-spend-metering) and completes the third axis of the enforcement envelope (spend)."

## Context

This feature carves User Story 4 out of `specs/002-manifest-enforcement` into its own
spec — the same pattern by which US2 became `003-manifest-invisibility` and US3 became
`004-credential-proxy`. It completes the third axis of the enforcement envelope (spend)
alongside the recipient/method scoping already enforced by the gate.

The following already exist and MUST NOT be re-specified here — this feature builds on them:

- The `{cap, window, on_breach}` spend struct (`lib/agent_os/manifest/spend.ex`).
- The per-action `cost` declared in the connector registry.
- The gate's per-action cost summation and `{:breach, :spend}` decision (`lib/agent_os/gate.ex`).
- The persisted single-writer per-agent `spend_ledger` state store (entry holds `spent` and `window_start`).

What this feature ADDS on top of that foundation: (1) make the **window** load-bearing
(fixed, resetting), (2) make **on_breach** driven by the declared manifest field rather
than hardcoded behaviour, (3) guarantee a breach-triggered kill is an **intentional stop**
that does not trip Phase-1 restart-once-and-alert supervision, and (4) make current spend
**visible per agent** on the legible surface without asking the agent.

## Clarifications

### Session 2026-06-29

- Q: When one action in a batch (the actions from a single agent run, evaluated in order) breaches the cap, do the within-cap actions earlier in the batch execute, or is the whole batch dropped? → A: Drop the whole batch — if any action in the run breaches the cap, NO action in that run executes (including within-cap actions before the breach), then `on_breach` fires. This preserves the current run-worker behaviour; it is conservative (a run that would breach commits nothing). Note this diverges from 002's per-action reading, which is superseded for v2.
- Q: Where does the spend meter (the ledger increment) live — at the gate-decision / run-worker boundary as today, or attached to the effector (the credential chokepoint from 004)? → A: Gate / run-worker boundary — the gate computes per-action cost and the `{:breach, :spend}` decision, and the run-worker increments the per-agent ledger post-gate for executed cost. The gate-decision point is the chokepoint meter; accounting is NOT moved onto the effector in v2.

## User Scenarios & Testing *(mandatory)*

The "user" of this feature is the human operator who declares and runs the (still
hand-written) agent, plus the substrate itself which must enforce that declaration. The
agent is the untrusted party and is never a beneficiary of trust. The operator declares
`spend: {cap, window, on_breach}` in the manifest and expects the substrate to enforce a
per-window cap, kill the run on breach as declared, leave a genuine crash distinguishable
from that kill, and let the operator see what each agent has spent — all without trusting
or querying the agent.

### User Story 1 - Spend is capped per window and resets at the boundary (Priority: P1)

The operator declares a cap of N over a daily window. Within a window, the cumulative cost
of executed actions accrues against the cap; an action whose cost lands cumulative spend
exactly at N is allowed, and the next over-cap action is blocked. When the window boundary
passes, accumulated spend resets to zero so the cap is per-window, not lifetime — the same
action blocked late in one window is permitted again in the next.

**Why this priority**: Without a real resetting window the cap is meaningless after the
first period — it becomes a one-shot lifetime limit. The window being load-bearing is the
core of this feature; everything else (breach dispatch, visibility) is about a cap that is
already real and windowed.

**Independent Test**: Drive the meter with deterministic per-action connector costs and a
small cap, controlling the clock. Submit actions until cumulative spend reaches exactly N
(allowed) and one more over-cap action (blocked). Advance the clock past the window
boundary and re-submit the previously blocked action — assert it is now permitted and that
spend was reset to zero at the boundary. No live model, no external service, no waiting on
a real clock.

**Acceptance Scenarios**:

1. **Given** a cap of N over a daily window with cumulative spend below N, **When** an
   action whose cost lands cumulative spend exactly at N is evaluated, **Then** it is
   allowed (the cap boundary is inclusive).
2. **Given** cumulative spend at N within the window, **When** the next action with
   non-zero cost is evaluated, **Then** it is blocked as a spend breach.
3. **Given** spend blocked late in one window, **When** the window boundary passes (clock
   advanced past `window_start` + window duration) and the run's spend check runs, **Then**
   spend is reset to zero before the check and the same action is permitted again in the
   new window.
4. **Given** a window in progress that has not reached its boundary, **When** a run
   executes, **Then** spend continues to accumulate against the existing window (no
   premature reset).

---

### User Story 2 - A breach fires the declared on_breach kill, distinct from a crash (Priority: P1)

When a spend breach occurs, the substrate fires the behaviour named in the manifest's
`on_breach` field (`kill` in v2), not a hardcoded default. The kill is a real stop of the
run — not a logged warning — and it is recorded as an intentional stop so the Phase-1
restart-once-and-alert supervisor does NOT restart it. A genuine child crash or OOM is
still treated as a fault and still restarts once, so enforcement and supervision do not
fight each other.

**Why this priority**: Without honouring the declared `on_breach`, the limit is decorative;
without distinguishing an intentional kill from a crash, the supervisor would fight the
enforcement by restarting a deliberately-stopped run. Both are required for the cap to be a
real boundary, so this story is co-critical with US1.

**Independent Test**: With a small cap, submit an over-cap action and assert the run stops
via the declared `on_breach` and the supervisor does not invoke restart-once-and-alert
(spy/inject the worker and supervisor). Separately, simulate a genuine abnormal child exit
(crash/OOM) and assert the supervisor still restarts exactly once — confirming the two
stop-causes are distinguishable. Deterministic, no live model.

**Acceptance Scenarios**:

1. **Given** a declared `on_breach` of `kill` and an over-cap action, **When** the breach
   occurs, **Then** the behaviour fired is the one named in the manifest (kill), selected by
   dispatching on the declared field rather than a hardcoded default.
2. **Given** a breach-triggered kill, **When** the supervisor observes the stop, **Then**
   it is treated as an intentional stop and restart-once-and-alert is NOT invoked.
3. **Given** a genuine child crash or OOM (not a breach), **When** the supervisor observes
   the abnormal exit, **Then** restart-once-and-alert still applies and the run is restarted
   exactly once.
4. **Given** a breach anywhere in a run's batch, **When** the kill fires, **Then** it is a
   real stop of the run that prevents EVERY action in that run from executing (the whole
   batch is dropped, including within-cap actions) — not merely a logged warning.

---

### User Story 3 - Current spend is visible per agent for the current window (Priority: P2)

The operator inspects the standing inventory (and/or run-trace) and sees, for each agent,
the spend for the current window reported as spent / cap / window — read from the legible
substrate surface without asking or querying the agent process.

**Why this priority**: Visibility is what lets the operator see what an agent is spending
and confirm the cap is working. It depends on US1's windowed ledger being correct but is
not itself required for enforcement, so it is P2 — enforcement (US1/US2) is the MVP; the
render is the operator-facing completion.

**Independent Test**: After driving some metered spend within a window, render the standing
inventory and assert it reports per-agent spent / cap / window for the current window,
sourced from the spend ledger state (not from the agent). Render again after a window reset
and assert spent is shown as zero for the new window. Deterministic, no live model.

**Acceptance Scenarios**:

1. **Given** an agent that has accrued spend in the current window, **When** the operator
   inspects the standing inventory, **Then** current spend is reported per agent as spent /
   cap / window for the current window.
2. **Given** the standing inventory render, **When** it reports spend, **Then** the value is
   read from the substrate's persisted ledger state, without communicating with the agent
   process.
3. **Given** a window that has just reset, **When** the operator inspects spend, **Then**
   spent is reported as zero against the cap for the new window.

---

### Edge Cases

- **Spend exactly at the cap boundary**: at the gate's per-action evaluation, an action
  whose summed cost lands cumulative spend exactly at the cap is approved; the next action
  over the cap is the breach (inclusive cap). Note: if a later action in the same run
  breaches, the whole batch is dropped per FR-012, so the at-cap action does not execute in
  that run either.
- **Window rollover mid-life**: spend accumulated in window W resets to zero at W's
  boundary; a run that straddles the boundary uses the reset value for its check.
- **Repeated resets**: if multiple window boundaries pass between runs (e.g. the agent was
  idle for several days), the next run still sees spent reset to zero for the current window
  (no compounding of skipped windows).
- **Breach kill vs. genuine crash**: the supervisor distinguishes an intentional on_breach
  kill from a real child crash/OOM so restart-once-and-alert applies only to the crash.
- **Zero-cost actions at the cap**: an action with zero cost at exactly the cap does not
  breach (it does not push cumulative spend over N).
- **No prior ledger entry**: an agent with no ledger entry yet is treated as spent = 0 with
  a window anchored at first use.
- **on_breach value other than kill**: only `kill` is implemented in v2; the schema may
  carry other values later, but no other value is enforced or tested now.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The spend `window` MUST be load-bearing: spend is a FIXED, RESETTING window —
  cumulative cost accrues within the period and resets to zero at the boundary, so the cap
  is per-window, not lifetime.
- **FR-002**: Before a run's spend check, the substrate MUST compare the current time
  against the ledger entry's stored `window_start` plus the window duration; if the current
  time is past that boundary, spent MUST be reset to zero and the window re-anchored before
  the check runs.
- **FR-003**: `daily` MUST be the only window value supported in v2 (the value set MAY
  extend in a later phase; only `daily` is implemented and tested now).
- **FR-004**: A spend breach MUST trigger the behaviour named in the manifest's `on_breach`
  field, selected by dispatching on the declared field — NOT a hardcoded default.
- **FR-005**: `kill` MUST be the only `on_breach` value implemented in v2; the `kill`
  behaviour MUST be a real stop of the run that prevents the over-cap action from executing,
  not merely a logged warning.
- **FR-006**: A breach-triggered kill MUST be recorded/signalled as an INTENTIONAL stop,
  distinguishable from an abnormal child exit, such that the Phase-1 restart-once-and-alert
  supervisor does NOT restart it.
- **FR-007**: A genuine child crash or OOM (a real fault, not a breach) MUST still be
  treated as an abnormal exit and MUST still trigger restart-once-and-alert (restart exactly
  once), preserving the existing Phase-1 supervision behaviour.
- **FR-008**: Current spend MUST be visible per agent for the current window on the legible
  surface (the standing inventory and/or run-trace) as spent / cap / window, read from the
  persisted ledger state WITHOUT communicating with the agent process.
- **FR-009**: The cap boundary MUST be inclusive at the gate's per-action evaluation: an
  action whose summed cost lands cumulative spend exactly at the cap is approved; only an
  action that pushes cumulative spend strictly over the cap is a breach. (Run-level
  disposition of a breaching batch is governed by FR-012.)
- **FR-010**: The current time used for window-boundary evaluation MUST be injectable so
  window rollover is testable deterministically without waiting on a real clock.
- **FR-011**: Spend MUST be metered using the existing per-action connector costs summed by
  the gate; this feature MUST NOT change the gate's allow/deny/recipient/method logic or the
  cost model.
- **FR-012**: When ANY action in a run's batch breaches the cap, the substrate MUST drop
  the WHOLE batch — no action in that run executes, including within-cap actions evaluated
  before the breaching one — and then fire `on_breach`. (Per-action partial execution is
  explicitly NOT done in v2; this preserves the current run-worker behaviour and supersedes
  002's per-action reading.)
- **FR-013**: The spend meter MUST remain at the gate / run-worker boundary: the gate
  computes per-action cost and the `{:breach, :spend}` decision, and the run-worker
  increments the per-agent ledger for executed cost post-gate. Accounting MUST NOT be moved
  onto the effector in v2.

### Key Entities *(include if feature involves data)*

- **Spend Ledger Entry (per agent)**: the persisted, single-writer record of an agent's
  spend within the current fixed window. Holds the cumulative `spent` (summed connector cost
  of executed actions) and the `window_start` anchor. Reset to zero and re-anchored when the
  window boundary passes. Source of both enforcement (the cap check) and visibility (the
  operator render). Already exists; this feature makes its `window_start` load-bearing.
- **Spend Constraint (manifest)**: the declared `{cap, window, on_breach}` per agent — `cap`
  a number, `window` a fixed resetting period (`daily` in v2), `on_breach` the behaviour to
  fire on breach (`kill` in v2). Already exists; this feature consumes `window` and
  `on_breach` rather than treating them as decorative.
- **Breach Stop Signal**: the intentional-stop marker that a breach-triggered kill produces,
  distinct from an abnormal-exit fault, consumed by the supervisor to decide whether
  restart-once-and-alert applies.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With a cap of N over a daily window and deterministic per-action costs, an
  action landing cumulative spend exactly at N is allowed and the next over-cap action is
  blocked — verified without a live model or external service.
- **SC-002**: After the window boundary passes (clock advanced in test), per-agent spend
  resets to zero and an action blocked in the prior window is permitted in the new window.
- **SC-003**: A spend breach fires the behaviour named in the manifest (`kill`), confirmed
  to be selected by dispatch on the declared field rather than a hardcoded path.
- **SC-004**: A breach-triggered kill causes no restart; a genuine child crash/OOM still
  restarts exactly once — both demonstrated in the same deterministic suite.
- **SC-005**: The operator can read per-agent spent / cap / window for the current window
  from the standing inventory without any communication with the agent process.
- **SC-006**: The entire feature's behaviour is verified by deterministic tests only — no
  live LLM, no external service, no Docker — driven by existing connector costs, a small
  cap, and an injectable clock.

## Assumptions

- The window is anchored at the ledger entry's `window_start`; the boundary is
  `window_start` + the window's duration. On reset, the window is re-anchored to the time of
  the resetting run (deterministic given the injectable clock). Calendar-aligned (e.g.
  midnight-UTC) anchoring is NOT required for v2.
- `daily` denotes a 24-hour fixed period for the purposes of boundary computation.
- The persisted `spend_ledger` state store remains the single source of truth for both the
  cap check and the operator render; no new persistence mechanism is introduced.
- The existing connector-registry per-action `cost` values are the cost model; no new cost
  source is introduced.
- The standing inventory render is the primary visibility surface; extending the run-trace
  is acceptable but not required if the inventory satisfies FR-008.
- The agent workload across the port boundary is unchanged; this is control-plane-only
  (Elixir) work.

## Out of Scope

- Event-triggers / message-triggers and approval-as-event-trigger (plan 03-05).
- The world-B hostile-agent verification (plan 03-06).
- The credential proxy (done, 004) and any change to its behaviour.
- Any change to the gate's allow / deny / recipient / method logic (03-01, done).
- New `on_breach` values beyond `kill`.
- Rolling (non-fixed / sliding) windows.
- Any generation (v3) work.

## Dependencies

- The deterministic gate and its `{:breach, :spend}` decision (`lib/agent_os/gate.ex`,
  spec 002 / plan 03-01) — landed.
- The connector registry and per-action `cost` (spec 002) — landed.
- The credential chokepoint / effector (spec 004 / plan 03-03) — landed.
- The persisted single-writer `spend_ledger` state store and the `{cap, window, on_breach}`
  spend struct — landed.
- The Phase-1 restart-once-and-alert supervisor (`lib/agent_os/run_supervisor.ex`) — landed.
