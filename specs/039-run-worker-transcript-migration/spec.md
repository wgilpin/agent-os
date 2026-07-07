# Feature Specification: Run-Worker Transcript Migration

**Feature Branch**: `039-run-worker-transcript-migration`
**Created**: 2026-07-07
**Status**: Draft
**Input**: User description: "Migrate the deployed agent runtime (run_worker) off the retired free-text {\"actions\":[…]} stdout protocol and onto the broker's tool-call channel as the single source of truth for what an agent did during a run."

## Overview

Feature 038 moved action selection, gating, and execution into the inference broker's
structured tool-call channel. During inference the capability rail evaluates each tool
call against the agent's manifest, executes granted calls, parks approval-required
calls for human approval, rejects ungranted or out-of-scope calls, and records every
outcome as a typed action transcript keyed by the run token. Generated agent bodies
now act *only* through that channel and finish by printing a single-line **outcome
record** (`{"outcome": "...", "reason": "..."}`) to stdout.

The deployed run worker never caught up. It still expects the agent's stdout to carry a
list of proposed actions (`{"actions":[…]}`), and then independently re-gates and
re-executes those actions a second time. Against a genuinely-generated agent — whose
stdout carries only the outcome record — the run worker sees no `actions` key, treats
the run as malformed, and skips all of its accounting (run log, spend, breach
handling). This spec migrates the run worker to treat stdout as the outcome record and
to source what the agent *did* from the action transcript, eliminating the second gate
and execution pass.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Generated agent run is recorded correctly (Priority: P1)

An operator deploys an agent generated with the current (038) synthesis prompt. When
the agent runs, its body acts entirely through the tool-call channel and prints only a
terminal outcome record to stdout. The run worker must record the run correctly:
outcome and reason drawn from stdout, and the tally of what the agent did (executed,
parked, rejected) drawn from the action transcript.

**Why this priority**: This is the core defect. Without it, every real generated agent
run is silently misclassified as malformed and produces no usable run log, spend
accounting, or breach handling. Nothing else in the feature matters until this works.

**Independent Test**: Drive the run worker with a stubbed agent body that prints an
outcome record to stdout and a pre-seeded action transcript containing granted, parked,
and rejected entries for that run token. Assert the run log reflects the outcome/reason
from stdout and the effect tallies from the transcript — with no live model call.

**Acceptance Scenarios**:

1. **Given** an agent whose stdout is `{"outcome":"completed","reason":"handled via tool channel"}` and a transcript with two granted and one rejected entry, **When** the run worker processes the run, **Then** the run is recorded as completed with the correct executed/rejected counts and is not flagged malformed.
2. **Given** an agent that prints a valid outcome record but whose transcript is empty (it took no actions), **When** the run worker processes the run, **Then** the run is recorded as a successful no-op with zero effects and no error.
3. **Given** an agent whose stdout is not a valid outcome record (missing `outcome`/`reason` or unparseable), **When** the run worker processes the run, **Then** the run is recorded as malformed with a clear reason, distinct from a successful run.

---

### User Story 2 - No double execution of effects (Priority: P1)

The capability rail already executed granted effects during inference. The run worker
must not run them again. A granted send/write must produce exactly one real side
effect per run, not two.

**Why this priority**: Double execution is a correctness and safety hazard — duplicate
external sends, duplicate writes, double spend. It is as critical as US1 and must land
together with it.

**Independent Test**: Seed a transcript with a granted effect whose connector records
each invocation; run the worker; assert the connector was invoked zero additional times
by the worker (the rail's execution during inference is the only one).

**Acceptance Scenarios**:

1. **Given** a transcript with one granted effect already executed by the rail, **When** the run worker processes the run, **Then** the run worker performs no further gating or execution of that effect and the side effect occurs exactly once for the run.
2. **Given** the run worker processes a tool-channel run, **When** it builds its run log, **Then** it does so without invoking the batch gate or the effector execution path.

---

### User Story 3 - Spend and breach accounting preserved (Priority: P2)

Spend accounting and spend-breach handling must continue to work, now derived from the
transcript and the broker's spend-ledger updates rather than from a stdout action list.
An agent that breaches its spend cap mid-run must still be recorded as breached and
handled per its breach policy.

**Why this priority**: Spend metering and breach enforcement are load-bearing safety
guarantees, but they build on the corrected run-recording path from US1, so they follow
it.

**Independent Test**: Seed a transcript and spend-ledger state that together represent a
run that crossed its cap; run the worker; assert the run is recorded as breached and the
configured breach action is taken — with no live model call.

**Acceptance Scenarios**:

1. **Given** a run whose recorded effects and ledger show spend at or above the manifest cap, **When** the run worker processes the run, **Then** the run is recorded as breached and the manifest's breach policy is applied.
2. **Given** a run whose spend stayed under the cap, **When** the run worker processes the run, **Then** the run is recorded as within budget and the reported spend equals the ledger's accounting for that run token.

---

### User Story 4 - Approval-required effects remain human-gated (Priority: P2)

An agent that attempts an approval-required action (e.g. an external send) has that
action parked by the rail into the pending-approvals queue during inference. The run
worker must reflect the parked effect in its run log without re-parking it, double-
counting it, or executing it.

**Why this priority**: Approval gating is a core trust boundary. The parking itself
already landed in 038; this story ensures the run worker's migration does not silently
break or duplicate it.

**Independent Test**: Seed a transcript with a parked entry and a pending-approvals
queue already holding the corresponding request; run the worker; assert the run log
shows one parked effect and the pending-approvals queue is unchanged (no second entry).

**Acceptance Scenarios**:

1. **Given** a transcript with one parked effect and a matching entry already in the pending-approvals queue, **When** the run worker processes the run, **Then** the run log reports exactly one parked effect and the queue still holds exactly one matching request.
2. **Given** a parked effect, **When** the run worker records the run, **Then** it does not execute the effect and does not add a duplicate approval request.

---

### Edge Cases

- **Empty or missing transcript for a completed run**: recorded as a successful no-op with zero effects, not as an error.
- **Malformed outcome record with a populated transcript**: the run is flagged malformed for legibility, but effects the rail already executed/parked are not undone — the transcript remains the record of what happened.
- **Legacy `{"actions":[…]}` stdout from an old stub or pre-038 agent**: rejected as malformed under the clean cutover (see Assumptions), with a reason that names the retired protocol, rather than silently re-gated.
- **Agent process crashes before printing any stdout**: recorded as a failed/malformed run; any effects already recorded in the transcript stand.
- **Transcript contains a rejected entry only**: recorded as a completed run that accomplished nothing actionable, with the rejection reason surfaced in the run log.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The run worker MUST interpret an agent's stdout as a terminal outcome record consisting of an outcome and a reason, used for run legibility and the run log — not as a list of proposed actions.
- **FR-002**: The run worker MUST source the effects performed during a run (granted, parked, rejected) from the action transcript keyed by that run's token, which the broker/rail populated during inference.
- **FR-003**: The run worker MUST NOT gate or execute agent effects itself for tool-channel runs; the batch-gate and effector-execution pass MUST be removed or bypassed for such runs.
- **FR-004**: Each granted effect MUST produce exactly one real side effect per run — the one performed by the rail during inference — with no additional execution by the run worker.
- **FR-005**: The run worker MUST preserve run-log accounting — counts of executed, parked, and rejected effects and the gate/rejection reasons — deriving them from the transcript instead of from a stdout action list.
- **FR-006**: The run worker MUST preserve spend accounting and spend-breach handling, deriving spend from the transcript and the broker's spend-ledger updates, and MUST apply the manifest's breach policy when a run breaches its cap.
- **FR-007**: Approval-required effects parked by the rail MUST be reflected in the run log without being re-parked, duplicated, or executed by the run worker.
- **FR-008**: A run whose stdout is not a valid outcome record MUST be recorded as malformed with a clear, distinct reason, separable from a successful run in the run log.
- **FR-009**: The system MUST document whether the retired `{"actions":[…]}` stdout protocol is fully removed (clean cutover) or tolerated during a transition window, and behave consistently with that decision.
- **FR-010**: The stub generation fixture and the tests that assert the old stdout shape MUST be updated to the new outcome-record-plus-transcript contract, and no test may depend on a live model call.
- **FR-011**: The action transcript MUST remain single-writer, keyed by run token; the run worker is a reader of the transcript and MUST NOT mutate another run's transcript.
- **FR-012**: Effect and outcome data structures exchanged between the rail, transcript, and run worker MUST be strongly typed rather than passed as untyped ad-hoc maps.
- **FR-013** *(added — discovery migration)*: The default discovery agent MUST act only through the broker tool-call channel and terminate with an outcome record; it MUST NOT emit a proposed-actions list. Its effects MUST be gated and executed by the rail (e.g. `kv_append` via a tool-channel executor) and recorded to the transcript.
- **FR-014** *(added — discovery migration)*: Discovery's tool-channel run MUST be testable without any live model — via a deterministic model stub over the broker's real UDS listener — preserving Constitution IV.

### Key Entities *(include if feature involves data)*

- **Outcome Record**: The terminal result an agent prints to stdout — an outcome (e.g. completed, refused) and a human-readable reason. The run worker's source of the run's disposition, not of its effects.
- **Action Transcript**: The typed, single-writer, per-run-token record of every tool call the rail evaluated during inference, each classified as granted, parked, or rejected with its connector, method, arguments, result, and (for rejections) a reason code. The run worker's source of what the agent did.
- **Run Log Entry**: The run worker's persisted record of a completed run — outcome, reason, effect tallies (executed/parked/rejected), spend, and breach status — now assembled from the outcome record plus the transcript.
- **Spend Ledger**: The broker-maintained accounting of spend per agent/run token, used together with the transcript to determine a run's spend and whether it breached its cap.
- **Pending-Approvals Queue**: The store the rail parks approval-required actions into during inference; the run worker reads but does not add to it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of runs from agents generated with the current synthesis prompt are recorded with a correct outcome and correct effect tallies (previously 0% — all were misclassified as malformed).
- **SC-002**: Each granted effect results in exactly one real side effect per run; zero duplicate sends, writes, or spend charges attributable to a second execution pass.
- **SC-003**: Spend and breach handling produce identical recorded results for equivalent runs before and after the migration, verified against seeded transcript/ledger fixtures.
- **SC-004**: Approval-required actions appear exactly once in both the run log and the pending-approvals queue; zero duplicates introduced by the run worker.
- **SC-005**: The full test suite passes with no live model calls, and at least one test drives the run worker against an outcome-record stdout plus a seeded transcript (the path no prior test covered).
- **SC-006**: A run with malformed stdout is distinguishable in the run log from a successful run in 100% of cases.

## Assumptions

- **Clean cutover — with discovery migrated in the same feature.** During implementation the clean-cutover premise proved false for one agent: the substrate's default *discovery* agent (`agents/discovery/main.py`) still emitted `{"actions":[…]}` and, being deterministic, never routed through the rail — so a pure run_worker cutover would silently break it. Rather than keep a compatibility window, the feature was **expanded (user decision, in-session)** to migrate discovery onto the broker tool-call channel too: discovery now asks the broker to reason and prints only an outcome record; its effects flow through the rail into the transcript. Discovery was always intended to be an LLM agent (its `call_inference_broker` was written but never wired up because no model existed yet). With discovery migrated, the cutover is genuinely clean everywhere and legacy-shaped stdout is treated as malformed (FR-009). See Phase 8 in tasks.md.
- The capability rail's approval-parking behavior (approval-required connectors parked, not executed) is already landed on this branch and is a prerequisite, not part of this work.
- The Stage-4 synthesis prompt rewrite (bodies act only via the tool channel and emit an outcome record) is already landed.
- The action transcript is populated by the rail during inference before the run worker reads it; the run worker runs after inference completes for a given run token.
- Tests drive behavior through provider/transport stubs and pre-seeded transcript and ledger fixtures; live model calls remain forbidden (Constitution IV).
- Data structures crossing module boundaries use the project's typed-struct conventions; no bare-map contracts are introduced (Constitution V), and the transcript stays single-writer keyed by run token (Constitution IX).

## Out of Scope

- The capability-rail approval-parking fix (already landed on this branch).
- The Stage-4 synthesis prompt rewrite (already landed).
- Any change to how the rail gates, executes, or records tool calls during inference — this feature only changes how the run worker *reads* the results.
- Changes to the human approval-resume flow that consumes the pending-approvals queue.
