# Phase 0 Research: Conformance Auditor

All decisions are constrained by the constitution (deterministic, agent-agnostic, FLAG-ONLY) and
the run-log format already emitted by `AgentOS.RunLog.append/2`. No NEEDS CLARIFICATION remain
after the 2026-06-30 clarification session; this document resolves the non-free design choices.

## Run-log format (existing, the only behavioural input)

A run record is a markdown line:

```
- [<iso8601>] status=<s> actions=<n> [trigger=<t>] [exit_code=<n>] [failure_cause=<c>]
  [items_in=<n> items_dropped=<n>] [approved_count=<n> rejected_count=<n> parked_count=<n>
  breached_count=<n> gate_reasons=<inspect-list>] <note>
```

Approval-resume records appear as e.g. `status=ok actions=0 trigger=approval-resume denied ref=ref_99`
(human denied a parked action) and `... trigger=approval-resume approved ref=ref_42`. Digest lines
(`- [...] digest: ...`) are not run records and are excluded.

## Decision 1 — Field mapping from run-log to the three legs

**Decision**:

| Signal | Source field(s) in window | Threshold |
|---|---|---|
| Leg 1 — quiet (health) | trailing consecutive records with `actions=0` | streak ≥ 3 |
| Leg 1 — sick (health) | any record `status=alert`; or latest record `items_dropped > 0` and its `items_dropped/items_in` share strictly exceeds the previous record's | ≥1 alert, or strictly-rising shed |
| Leg 2a — denied-approval (trust) | records with `trigger=approval-resume` and note `denied` | count ≥ 3 |
| Leg 2b — gate-breach (trust) | `breached_count > 0` OR `gate_reasons` ≠ `[]` on any record | ≥ 1 (tripwire) |

**Rationale**:
- Leg 2a maps to **human-denied parked actions** (`approval-resume … denied`), *not* the gate's
  `rejected_count`. Constraint rejection at proposal time is per-action enforcement the gate already
  owns; re-counting it would violate FR-003 (non-redundancy). The "reaching for the locked door"
  pattern the spec wants is the agent repeatedly proposing approval-required actions a human keeps
  refusing.
- Leg 2b is a true tripwire: a recorded manifest-breach attempt (`breached_count`/`gate_reasons`)
  is the agent reaching past the approval flow entirely; one is enough.
- Quiet uses a **trailing** streak (consecutive most-recent no-action runs), not a count anywhere in
  the window, so a single recent productive run clears it.

**Alternatives considered**: counting `rejected_count` toward Leg 2a (rejected — redundant with the
gate, FR-003); using `parked_count` alone (parked ≠ denied — a parked action may still be approved).

## Decision 2 — Admin alert channel (feedback-loop avoidance)

**Decision**: the admin alert reuses the *mechanism* of `AgentOS.Alerter` (a `Logger` call plus an
append to git-backed markdown) but writes to a **separate** `data/admin_alerts.md`, never a
`status=alert` line in `data/run_log.md`.

**Rationale**: `Alerter.alert/2` appends `status=alert` to the run-log. The auditor's sick signal
reads `status=alert` from that same run-log. If the auditor raised an alert *into* the run-log, the
next pass would read it back and mark the agent sick — a self-amplifying feedback loop. A distinct
channel keeps the behavioural input (run-log) and the auditor's own output (admin alerts) cleanly
separated, and gives a future admin UI a dedicated legible file to read.

**Alternatives considered**: reuse `Alerter.alert/2` directly (rejected — pollutes the run-log and
creates the loop); emit only via `Logger` with no persisted file (rejected — a future admin UI needs
a durable, legible artifact, consistent with Principle VIII).

## Decision 3 — Window definition

**Decision**: the window is the last **N = 20** records carrying `status=` (digest lines excluded),
N configurable via opts/app-config. Quiet is the trailing `actions=0` streak within the window;
denied-approval is a count within the window; gate-breach is presence within the window.

**Rationale**: count-based per the clarification (robust to irregular cadence). N=20 ≈ three weeks of
a daily agent — long enough for the count-based denied signal to be meaningful, bounded enough to read
cheaply. The exact N is not load-bearing (thresholds are defined relative to the window) so it is a
tunable default, not another clarification.

**Alternatives considered**: time-based window (rejected in clarification — couples to wall-clock,
fixtures become time-sensitive).

## Decision 4 — Scheduling shape

**Decision**: a dedicated `AgentOS.ConformanceAuditor.Scheduler` GenServer, mirroring
`AgentOS.Scheduler`'s self-rescheduling `Process.send_after(:fire)` pattern, that calls
`ConformanceAuditor.run_pass/1` daily. It is added to the supervision tree alongside the existing
`Scheduler`. The pure `audit/2` logic is separate and process-free.

**Rationale**: separation of concerns — the run trigger (`Scheduler`) fires the agent; the audit
trigger fires the auditor. Mirroring the proven pattern keeps it boring (Principle I). Keeping `audit/2`
pure makes the load-bearing logic unit-testable with zero process machinery (Principle III).

**Alternatives considered**: extend `Scheduler` to fire both (rejected — conflates two lifecycles,
and the audit wants to run *after* a run has written its record); fold the audit into the run pipeline
/ `RunWorker` (this was the user's rejected option C — couples the auditor to the agent run).

## Decision 5 — Escalation semantics for the alert (FR-013)

**Decision**: `run_pass/1` reads the previously persisted verdict before computing the new one. It
emits an admin alert only for flags that are **newly raised or escalated** relative to the stored
verdict (a flag absent before and present now, or risen in severity). Re-persisting an unchanged
flagged verdict emits no alert; a flag that has cleared emits no alert (it simply disappears from the
verdict). This yields "exactly one alert per new/escalated flag" (SC-008) and avoids daily re-alerting
on a standing condition.

**Rationale**: an alert is an edge-triggered notification, not a level reminder; daily duplicate alerts
on an unchanged condition would train the future admin UI's reader to ignore them.

**Alternatives considered**: alert on every pass where any flag is present (rejected — noisy, fails
SC-008's "exactly one"); alert on clear too (out of scope — the spec only requires alert on raise/escalate).

## Decision 6 — Determinism & loud failures

**Decision**: `audit/2` is a pure function of `(records, purpose, opts)` with no `DateTime.utc_now`
inside the verdict computation (any timestamp is supplied via opts for the persisted `computed_at`
only, not for any threshold). A run-log line that fails to parse is skipped with a `Logger.warning`
naming the offending line; the rest of the trace still audits.

**Rationale**: SC-004 reproducibility requires no hidden clock/state in the decision; Principle VI
forbids silent drops.
