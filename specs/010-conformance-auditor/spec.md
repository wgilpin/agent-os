# Feature Specification: Conformance Auditor

**Feature Branch**: `010-conformance-auditor`
**Created**: 2026-06-30
**Status**: Draft
**Input**: User description: "Conformance auditor — a post-deploy, FLAG-ONLY component that reads an agent's run-traces and raises conformance/trust flags in the standing inventory (roadmap plan 04-02, Phase 4 Generation MVP; REQ-check-conformance)."

## Overview

The deterministic gate already prevents an agent from doing anything outside its manifest —
a single forbidden action (wrong recipient, ungranted type, over-spend) is blocked and
recorded at enforcement time. But the gate judges one action at a time and has no memory:
it cannot see an agent that has quietly stopped doing its job, nor an agent that keeps
*reaching* for actions it is not cleared for. Those are questions about an agent's
behaviour over time — "is this still an agent I should trust?" — not about whether a single
action is allowed.

This feature adds a substrate-side **conformance auditor**: a post-deploy component that
reads the legible run-log the substrate already writes and raises flags about an agent's
behaviour. It is a **smoke detector, explicitly not the firewall**. It can raise or clear a
flag; it can never bless an agent, never grant a pass, and never gate, block, or approve a
deployment. The deterministic gate remains the only enforcement boundary.

The auditor sits strictly **above** the gate and reads only what a human could read — the
recorded run-traces (`data/run_log.md`) plus the agent's stated purpose (the manifest's
one-line purpose contract). It never reads agent internals, and never consults the manifest
as an enforcement input.

Like 04-01 (capability render) this is **generation-independent**: it is built and proven on
the EXISTING hand-written discovery agent, with no generation, no orchestrator, and **no LLM
anywhere in it**. Its verdicts render as provenance in the standing inventory next to the
04-01 capability view, so a human reads each agent's flagged/clean status — and the specific
flags raised — without asking the agent.

This slice delivers **two deterministic legs** and explicitly **defers a third**:

- **Leg 1 — Omission / health** (deterministic): the agent has gone quiet or sick.
- **Leg 2 — Reached-for-what-it-wasn't-cleared-for** (deterministic, the load-bearing leg):
  an aggregate behavioural signature of an agent probing actions it is not cleared for.
- **Leg 3 — Semantic drift** (DEFERRED, out of scope): acting on the wrong *content* through
  a permitted channel — needs an LLM, deferred to the generation pipeline plans (04-05+).

The defining constraint of the whole feature: the auditor must **not re-flag what the gate
already enforces per action**. Re-reporting blocked recipients/types or over-spend would be
redundant. The auditor's only value is the signals the gate is structurally blind to:
omission (the gate never requires an action) and patterns across traces (the gate has no
memory).

## Clarifications

### Session 2026-06-30

- Q: What trace window does the auditor measure signals over? → A: Count-based — the most recent N run-log records for the agent (default N = 20, configurable), not a time span.
- Q: When does the auditor compute a verdict? → A: A scheduled audit pass computes and persists a per-agent verdict to substrate state; the inventory renders the persisted verdict. Additionally, raising a flag emits an admin alert for a future admin UI (notification-only — it never gates, blocks, or approves anything).
- Q: How long a no-action streak raises the "gone quiet" health flag? → A: 3 or more consecutive no-action runs.
- Q: How is an "elevated denied-approval rate" defined for the trust flag? → A: Absolute count — 3 or more denied approval-required actions within the window (one or two denials never flag).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A human sees an agent reaching for what it isn't cleared for (Priority: P1)

A person responsible for a running agent opens the standing inventory. For the discovery
agent they see a clear conformance status. When the agent has been repeatedly attempting
actions it is not cleared for — actions routed for human approval and denied, or actions the
gate blocked outright as a manifest breach — the inventory shows a **trust flag** naming that
behavioural signature, so the human can investigate an agent that is behaving like one that
should not be trusted, even though the gate held every time.

**Why this priority**: This is the load-bearing reason the auditor exists. The gate blocks
each attempt in isolation and forgets it; nothing else surfaces the *pattern* of an agent
probing its boundaries. It is the safety/trust signal and the acceptance anchor. Without it
the feature is only a health monitor.

**Independent Test**: Feed the auditor a run-trace in which an agent accumulates denied
approval-required actions and/or a gate-breach record, and confirm it raises the
corresponding trust flag with the correct severity, while a clean trace raises no such flag.
No live agent or generation required.

**Acceptance Scenarios**:

1. **Given** a run-trace containing one record with a gate-breach (a recorded manifest-breach
   attempt — the agent reached past the approval flow for something it had no grant for),
   **When** the auditor reads the trace, **Then** it raises a trust flag for that agent on the
   strength of that single record (hair-trigger; a breach attempt is never tolerated as
   "within normal").
2. **Given** a run-trace in which 3 or more of the agent's approval-required actions were
   denied within the window, **When** the auditor reads the trace, **Then** it raises a trust
   flag for the denied-approval pattern.
3. **Given** a run-trace with only one or two denied approval-required actions and no other
   anomaly, **When** the auditor reads the trace, **Then** it raises **no** trust flag — a
   handful of denials is the approval flow working as designed, not a behavioural signature.
4. **Given** any run-trace, **When** the auditor reaches a verdict, **Then** it only ever
   raises or clears flags — there is no code path by which it can return a pass, approve an
   action, or gate a deployment.
5. **Given** a scheduled audit pass that newly raises (or escalates) a flag for an agent,
   **When** the pass completes, **Then** it emits an admin alert carrying the agent identity
   and flag type for a future admin UI to surface — and that alert changes no deployment or
   action outcome (notification-only).

---

### User Story 2 - A human sees an agent that has gone quiet or sick (Priority: P2)

A person opens the standing inventory and, for an agent that has stopped producing useful
work — a run of cycles doing nothing, or runs ending in alert / shedding their input — sees
a **health flag** describing that the agent appears to have gone quiet or sick. They can act
on a discovery agent that has discovered nothing, which no other component reports because
doing nothing breaches no rule.

**Why this priority**: A genuine, uniquely-auditor signal (the gate is permissive about
absence; spend-kill never fires on a no-op; supervision never fires without a crash), but it
is a usefulness/health concern rather than a safety one, so it ranks below the trust signal.

**Independent Test**: Feed the auditor a run-trace with a streak of no-action runs (and
separately a streak of alert/dropped-input runs) and confirm it raises a health flag; feed a
trace of normal productive runs and confirm it does not.

**Acceptance Scenarios**:

1. **Given** a run-trace with a streak of 3 or more consecutive runs that took no action,
   **When** the auditor reads the trace, **Then** it raises a health flag indicating the agent
   has gone quiet.
2. **Given** a run-trace with runs ending in alert status or shedding a rising share of their
   input, **When** the auditor reads the trace, **Then** it raises a health flag indicating
   the agent appears sick.
3. **Given** a run-trace of normal productive runs, **When** the auditor reads the trace,
   **Then** it raises no health flag.

---

### User Story 3 - A reviewer trusts the verdict because it is computed only from the record (Priority: P3)

A reviewer trusts the conformance status because it is derived solely from the recorded
run-traces and the agent's stated purpose — the same legible material a human could read
themselves — and from nothing inside the agent. There is no path by which the auditor reads
agent internals or is influenced by the agent's own claims about itself.

**Why this priority**: Trace-sourcing is what makes the verdict trustworthy and is the reason
a non-trusted agent cannot talk its way to a clean status. It is a property of how every flag
is computed rather than a separate user journey, so it underpins US1/US2 rather than standing
alone.

**Independent Test**: Confirm the auditor's verdict for a fixed run-trace is identical
regardless of agent state or agent-provided content, and that it depends only on the trace
plus the stated purpose.

**Acceptance Scenarios**:

1. **Given** a fixed run-trace and stated purpose, **When** the auditor runs twice against
   different agent runtime states, **Then** it returns the identical verdict both times.
2. **Given** an agent that asserts it is conforming, **When** the auditor runs, **Then** the
   verdict is unaffected by that assertion and is computed only from the recorded trace.

---

### Edge Cases

- **Empty / brand-new agent**: an agent with no run-traces yet (no history) MUST produce a
  defined verdict — clean / insufficient-data, never an error and never a spurious flag.
- **Short history**: a trace shorter than a rate window MUST still resolve the hair-trigger
  breach signal, while rate-based signals report insufficient-data rather than a false flag.
- **Multiple flags at once**: an agent that is simultaneously quiet AND reaching MUST surface
  every applicable flag, not just the first — totality of flags, none suppressed.
- **Flag clearing**: once the flagged behaviour no longer appears within the trace window, the
  flag MUST be able to clear, so the status reflects current behaviour rather than a permanent
  mark.
- **Malformed / partial run-log line**: an unparsable record MUST be skipped without crashing
  the auditor or silently dropping the whole trace.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The auditor MUST be FLAG-ONLY — it can only raise or clear conformance flags,
  and MUST have no code path that returns a pass, approves an action, or gates/blocks/approves
  a deployment. (REQ-check-conformance)
- **FR-002**: The auditor MUST compute every verdict solely from recorded run-traces
  (`data/run_log.md`) and the agent's stated purpose (the manifest's one-line purpose
  contract), and MUST NOT read agent internals or treat the manifest as an enforcement input.
- **FR-003**: The auditor MUST NOT re-flag conditions the deterministic gate already enforces
  per action (wrong recipient/method, ungranted action type, over-spend); these are the gate's
  responsibility and reporting them would be redundant.
- **FR-004**: The auditor MUST raise a **health flag** when an agent has gone quiet (a streak
  of 3 or more consecutive no-action runs) or sick (any run in the window ending in alert
  status, or the latest run dropping a strictly greater share of its input than the previous
  run — i.e. `items_dropped > 0` and `items_dropped/items_in` strictly higher than the prior
  record) over the trace window. (Leg 1)
- **FR-005**: The auditor MUST raise a **trust flag** for the denied-approval pattern when 3 or
  more approval-required actions were denied within the trace window; one or two denied
  approval-required actions MUST NOT raise this flag. (Leg 2a — count-based)
- **FR-006**: The auditor MUST raise a **trust flag** on a gate-breach signal — a recorded
  manifest-breach attempt — on the strength of a single occurrence (hair-trigger), without
  requiring a rate. (Leg 2b — tripwire)
- **FR-007**: The auditor MUST surface every applicable flag for an agent simultaneously (no
  suppression or collapsing of one flag by another), and MUST be able to clear a flag once the
  flagged behaviour no longer appears within the trace window.
- **FR-008**: The auditor's verdict for an agent — a clean/flagged status plus the specific
  flag(s) raised — MUST be rendered as provenance in the standing inventory next to the
  capability view, readable by a human without querying the agent. The inventory renders the
  persisted verdict (FR-012) rather than recomputing it.
- **FR-009**: The auditor MUST produce a defined verdict for an agent with no or short history
  (clean / insufficient-data) rather than erroring or raising a spurious flag, and MUST skip an
  unparsable run-log record without failing the whole audit.
- **FR-010**: The auditor MUST contain no LLM and no semantic/content judgement; both legs are
  mechanical counts and thresholds over run-log fields. Content-based semantic-drift detection
  is explicitly out of scope for this feature.

- **FR-011**: The auditor MUST evaluate all signals over a **count-based** trace window — the
  most recent N run-log records for the agent (default N = 20, configurable), never a time
  span — with these thresholds: the quiet/health flag fires at 3 or more consecutive no-action
  runs (FR-004); the denied-approval trust flag fires at 3 or more denied approval-required
  actions within the window (FR-005); the gate-breach trust flag fires on a single occurrence
  (FR-006).
- **FR-012**: The auditor MUST run as a **scheduled audit pass** that computes and persists a
  per-agent conformance verdict to substrate state; the standing inventory reads that persisted
  verdict (FR-008) rather than recomputing it inline. The persisted verdict MUST remain a pure
  function of the run-traces and stated purpose (FR-002), so the same trace yields the same
  stored verdict.
- **FR-013**: When the audit pass newly raises or escalates a flag, the auditor MUST emit an
  **admin alert** (carrying agent identity and flag type) for a future admin UI to surface. The
  alert is notification-only and MUST NOT gate, block, approve, or otherwise influence any
  deployment or action — preserving FLAG-ONLY (FR-001).

### Key Entities *(include if feature involves data)*

- **Run-trace**: the recorded history of an agent's runs (from `data/run_log.md`). Per-run
  fields include status, actions taken, items-in / items-dropped, trigger, and the gate
  outcome fields (approved / rejected / parked / breached counts and gate reasons). The sole
  behavioural input to the auditor.
- **Stated purpose**: the agent's one-line purpose contract from its manifest — the reference
  the auditor's (future) semantic leg would compare against; in this slice it identifies the
  agent and frames the flags, and is read non-enforcingly.
- **Conformance verdict**: the auditor's output for an agent — an overall clean/flagged status
  plus the set of specific flags raised (health, denied-approval, gate-breach), each with a
  severity. Computed and persisted by the scheduled audit pass and rendered as provenance in
  the inventory.
- **Flag**: a single raised signal with a type (health / denied-approval-count / gate-breach),
  a severity (e.g. hair-trigger vs count-based), and a human-readable description.
- **Admin alert**: a notification emitted when a flag is newly raised or escalated, carrying
  the agent identity and flag type, for a future admin UI to surface. Never alters a deployment
  or action outcome.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For a run-trace containing a single gate-breach record, the auditor raises a
  trust flag 100% of the time; for a clean trace it raises that flag 0% of the time.
- **SC-002**: One or two denied approval-required actions raise no trust flag, while a trace
  with 3 or more denials within the window always does — verifiable from fixed trace fixtures.
- **SC-003**: The auditor raises a health flag for every no-action streak of 3 or more
  consecutive runs, and for alert/shed-input runs, and raises none for a normal productive
  trace.
- **SC-004**: 100% of the auditor's verdicts are reproducible from the run-trace and stated
  purpose alone — the same trace yields the same verdict regardless of agent runtime state,
  and no verdict depends on agent internals or agent self-assertion.
- **SC-005**: A non-technical reader can open the standing inventory and, for the discovery
  agent, correctly read its clean/flagged status and the named flag(s) without consulting the
  agent or the raw run-log.
- **SC-006**: No auditor verdict re-reports a per-action condition the gate already enforced
  (wrong recipient/method, ungranted type, over-spend) — auditable across the flag set.
- **SC-007**: The auditor never emits a pass, approval, or deploy-gate outcome under any
  input — confirmed by exercising it against breach, denial, omission, and clean traces.
- **SC-008**: Each newly raised or escalated flag emits exactly one admin alert carrying the
  agent identity and flag type, and no admin alert changes any deployment or action outcome —
  verifiable from fixed trace fixtures.

## Assumptions

- The legible run-log (`data/run_log.md`) is the canonical run-trace source and already
  records the per-run fields the two deterministic legs depend on (status, actions,
  items-in/dropped, trigger, and the gate outcome counts/reasons). No new instrumentation of
  the agent is in scope; if a needed field is absent, surfacing it is a run-log concern, not an
  auditor concern.
- The feature targets the existing single hand-written discovery agent (generation-independent,
  same "earn it on easy mode first" discipline as 04-01). Multi-agent rendering follows the
  inventory's existing per-agent structure.
- The standing inventory (04-01 capability view) is the surface for the verdict; the auditor
  contributes a provenance block there rather than introducing a new UI.
- A "denied approval-required action" (Leg 2a) is a parked action a human then denied, recorded
  in the run-log as an `approval-resume … denied` entry. The auditor reads those recorded
  outcomes and does NOT re-derive which actions require approval. `rejected_count` (the gate
  rejecting an action at proposal time on a constraint) is explicitly NOT counted toward
  denied-approval — that is per-action enforcement the gate already owns (FR-003 non-redundancy).
- The trace window is count-based with a configurable default of the last 20 run-log records;
  the exact default is tunable and not load-bearing for correctness (the thresholds are defined
  relative to the window).
- The scheduled audit pass runs alongside the existing daily run cycle (the discovery agent's
  daily timer); a separate cadence can be set later but daily is assumed for this slice.
- The admin alert reuses the substrate's existing alerting path (the same mechanism as
  restart-once-and-alert); the admin UI that would surface it is OUT OF SCOPE — this feature
  only emits the alert signal such a UI would consume.
- The auditor only EXPOSES a clean/flagged signal (and an admin alert). Wiring that signal into
  envelope-eligibility or any deploy decision is the responsibility of a later plan (04-03) and
  is out of scope here.
- Semantic-drift (content-vs-purpose) detection, the LLM, review modes, the envelope predicate,
  deploy-on-green, and pre-deploy security-review are all out of scope and belong to later
  plans (04-03, 04-05+, 04-08/04-09).
