# Feature Specification: Event-, Message-, and Approval-as-Event Triggers

**Feature Branch**: `007-event-message-triggers`
**Created**: 2026-06-29
**Status**: Draft
**Input**: User description: "Event-triggers, message-triggers, and approval-as-event-trigger for declared agents (roadmap plan 03-05, Phase 3 Manifest Enforcement; requirements REQ-trigger-event and REQ-trigger-message). Builds on the time-trigger from Phase 1."

## Overview

An agent's manifest already declares which triggers may fire it — `time`, `event {name}`, and
`message` — and all three are accepted by the manifest, but only `time` actually causes a run. This
feature makes `event` and `message` triggers *active*, and reuses the event mechanism to model
**approval** of a held action as just another event. The unifying principle is that the **substrate**
decides when an agent fires; the agent never fires itself or another agent, and an agent only ever
fires on a trigger its own manifest enumerates. This is the second-to-last slice of Phase 3
(Manifest Enforcement); only world-B hostile-agent verification remains after it.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Event-trigger fires a declared agent (Priority: P1)

A named event arrives at the substrate (e.g. "a bookmark was saved"). The substrate looks at the
target agent's manifest, finds a matching `event` trigger by name, and fires exactly one run for that
agent — through the same supervisor → port → child path the daily timer uses — delivering the event's
payload as the run's input. An event whose name is **not** listed in that agent's manifest triggers
causes nothing to happen. Trigger eligibility is an enforced allowlist, exactly like the gate's grant
allowlist.

**Why this priority**: Event-triggering is the foundational mechanism; message-triggering and
approval both reuse it. It is the smallest slice that proves the substrate can fire an agent on a
manifest-declared external signal, and it is independently shippable on its own.

**Independent Test**: Configure an agent whose manifest declares an `event` trigger named `X`. Submit
an event named `X` to the substrate and observe exactly one run fire with the event payload as input.
Submit an event named `Y` (not in the manifest) and observe no run fires. Both outcomes are visible in
the run-log without consulting the agent.

**Acceptance Scenarios**:

1. **Given** an agent whose manifest declares an `event` trigger named `bookmark_saved`, **When** an event named `bookmark_saved` with a payload is admitted to the substrate, **Then** exactly one run fires for that agent, the payload is delivered as the run's input, and the run-log records the run with trigger provenance identifying it as an event named `bookmark_saved`.
2. **Given** the same agent, **When** an event named `unknown_event` is admitted, **Then** no run fires for that agent and nothing is added to that agent's run-log.
3. **Given** an agent whose manifest declares **no** `event` trigger, **When** any named event is admitted, **Then** no run fires for that agent.
4. **Given** two events named `bookmark_saved` admitted in quick succession, **When** the substrate processes them, **Then** each admitted event fires its own single run (one event → one run), never zero or many for a single event.

---

### User Story 2 - Message-trigger wakes an agent; the operator is just another process (Priority: P2)

An agent that declares a `message` trigger can be woken by a message addressed to it. The message
content is delivered as the run's input. The canonical sender is the human operator via chat — but the
operator is modelled as *just another process* sending a message, not a privileged back channel. Any
admitted message to a message-triggered agent fires a run the same way.

**Why this priority**: This delivers the "you, via chat, are another process" property from the Phase 3
success criteria and gives the operator a direct way to invoke an agent on demand. It depends on the
same substrate intake-and-dispatch path as event-triggering but is a distinct, separately testable
delivery channel.

**Independent Test**: Configure an agent whose manifest declares a `message` trigger. Send it a message
(as the operator) and observe one run fires with the message as input. Configure a second agent with no
`message` trigger, send it a message, and observe no run fires.

**Acceptance Scenarios**:

1. **Given** an agent whose manifest declares a `message` trigger, **When** the operator sends a message addressed to that agent, **Then** exactly one run fires for that agent, the message is delivered as the run's input, and the run-log records the run with trigger provenance identifying it as a message.
2. **Given** an agent whose manifest declares **no** `message` trigger, **When** a message is addressed to that agent, **Then** no run fires for that agent and the delivery is rejected.
3. **Given** a message addressed to an agent that does not exist in the inventory, **When** it is admitted, **Then** no run fires and the delivery is rejected without error to other agents.

---

### User Story 3 - Approval of a held action is an event-trigger (Priority: P2)

When a proposed action requires human approval, the substrate holds the action pending rather than
executing it (this builds on the existing "parked" disposition the gate already produces). The action
sits in a visible pending state with a stable reference. When a human approval arrives — modelled as an
event keyed to that reference — the substrate deterministically executes exactly that held action at
the action chokepoint. A denial drops the held action without executing it. The decision to release is
the substrate's; the agent cannot release its own held action.

**Why this priority**: This is the load-bearing human-in-the-loop property of Phase 3: it proves that
approval is not a bespoke side channel but the same enforced event mechanism, and that a held action is
released by — and *only* by — a matching approval. It reuses US1's event machinery plus the gate's
existing pending-action store, so it is independently testable.

**Independent Test**: Drive a run that produces an action the manifest marks as requiring approval.
Confirm the action is held (not executed), is visible in the inventory with a reference, and does not
execute on its own. Submit a matching approval event and confirm exactly that action executes at the
chokepoint. Separately, submit a denial and confirm the held action is dropped without executing.

**Acceptance Scenarios**:

1. **Given** a run that proposes an action requiring approval, **When** the gate evaluates the batch, **Then** the action is held pending (not executed), is recorded with a stable reference, and is visible in the inventory and run-log without consulting the agent.
2. **Given** a held action with reference `R`, **When** an approval event for reference `R` is admitted, **Then** exactly that held action — and no other — executes at the action chokepoint, and the resolution is recorded in the run-log with provenance identifying it as an approval-resume.
3. **Given** a held action with reference `R`, **When** a denial for reference `R` is admitted, **Then** the held action is dropped without executing and the denial is recorded.
4. **Given** a held action with reference `R`, **When** an approval event arrives for a reference that does not match any held action, **Then** no action executes.
5. **Given** a held action with reference `R`, **When** the agent's own output attempts to self-approve reference `R`, **Then** the held action is **not** released (approval cannot originate from the agent).

---

### Edge Cases

- **Spoofing via untrusted input**: The discovery agent reads untrusted web content. An event name,
  message, or approval reference appearing *inside* agent-read web input or agent output MUST NOT cause
  any agent to fire or any held action to be released. Trigger signals are admitted only through the
  substrate's own intake, never inferred from agent-side data.
- **Event for the wrong agent**: An event name that matches agent A's manifest but is addressed to /
  evaluated for agent B does not fire B unless B's manifest independently declares it.
- **Duplicate approvals**: A second approval for an already-resolved reference is a no-op (the action
  executes at most once).
- **Approval after the originating run ended**: A held action persists across the end of the run that
  proposed it; approval can arrive later and still execute exactly that action.
- **Unknown / malformed payload**: An admitted event or message with a missing or malformed payload is
  rejected at intake and fires no run.
- **Concurrent fires**: Multiple eligible triggers for the same agent each produce their own single run;
  the substrate never collapses two distinct admitted signals into one run or drops one silently.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The substrate MUST fire a run for an agent when an admitted event's name matches an `event` trigger enumerated in that agent's manifest, delivering the event payload as the run's input. *(REQ-trigger-event)*
- **FR-002**: The substrate MUST take no action for an agent when an admitted event's name does not match any `event` trigger in that agent's manifest (allowlist semantics; default-deny).
- **FR-003**: The substrate MUST fire a run for an agent when a message is admitted addressed to that agent and that agent's manifest declares a `message` trigger, delivering the message as the run's input. *(REQ-trigger-message)*
- **FR-004**: The substrate MUST reject a message addressed to an agent whose manifest does not declare a `message` trigger, firing no run.
- **FR-005**: The human operator MUST be able to send a message to a message-triggered agent through the same admitted-message path used by any other sender, with no privileged shortcut that bypasses manifest enforcement.
- **FR-006**: The substrate MUST hold (not execute) any proposed action whose manifest disposition requires approval, recording it with a stable reference and an unexecuted state.
- **FR-007**: The substrate MUST execute a held action when, and only when, a matching approval is admitted for its reference, executing exactly that action at the action chokepoint and no other.
- **FR-008**: The substrate MUST drop a held action without executing it when a matching denial is admitted for its reference.
- **FR-009**: An agent MUST NOT be able to fire itself, fire another agent, or release its own held action; the decision to fire or release is made solely by the substrate.
- **FR-010**: Trigger signals (events, messages, approvals) MUST be attributed to a substrate-controlled intake and MUST NOT be derivable from, or forgeable by, untrusted web input read by an agent or by agent output.
- **FR-011**: Each fire MUST be recorded in the run-log with trigger provenance distinguishing time, event (with name), message, and approval-resume, consistent with how the existing time/manual triggers are recorded.
- **FR-012**: A held action MUST be visible in the standing inventory (with its reference and pending state) so an observer can see what is awaiting approval without consulting the agent.
- **FR-013**: Each admitted event or message MUST result in at most one run for the target agent (one signal → one run); a held action MUST execute at most once regardless of duplicate approvals.
- **FR-014**: A held action MUST persist beyond the end of the run that proposed it, so that approval arriving later still executes exactly that action.
- **FR-015**: Firing on any trigger type MUST route through the existing single-supervisor → single-port → child run path; no trigger type may introduce an alternate execution path that bypasses the gate, credential proxy, or spend metering.

### Key Entities

- **Trigger declaration**: An entry in an agent's manifest naming an eligible firing condition (`time`, `event {name}`, or `message`). The allowlist of how an agent may be fired.
- **Admitted signal**: An event (named, with payload), a message (addressed to an agent, with content), or an approval/denial (keyed to a held-action reference) that has entered the substrate through its own controlled intake — the only trustworthy origin of a fire.
- **Run input**: The payload (event) or content (message) delivered to a fired run as its hand-input, analogous to the input the daily timer-fired run receives.
- **Held action (pending approval)**: A proposed action the gate has parked because its manifest disposition requires approval; carries a stable reference, the action, its grant, and an unexecuted state; persists until approved (executed once) or denied (dropped).
- **Trigger provenance**: The recorded origin of a fire (time / event-name / message / approval-resume), written to the run-log and surfaced in the inventory.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A manifest-declared event reliably fires exactly one run for the target agent, with the event payload delivered as input, in 100% of admitted-matching cases.
- **SC-002**: An event whose name is not in the target agent's manifest fires zero runs in 100% of cases (no false fires).
- **SC-003**: A message to a message-triggered agent fires exactly one run with the message as input; a message to an agent lacking a `message` trigger fires zero runs — both in 100% of cases.
- **SC-004**: A held action never executes until a matching approval is admitted, and when approved executes exactly once; a denied held action executes zero times — verifiable in 100% of cases.
- **SC-005**: No event name, message, or approval reference originating from untrusted web input or agent output can cause any fire or any held-action release — guaranteed *by construction* (the sandboxed agent has no channel to the substrate-side intake), confirmed by a negative test that an agent-originated reference never resolves (zero forged fires).
- **SC-006**: Every fire is attributable from the run-log alone to its trigger type (time / event / message / approval-resume) without consulting the agent, and every held action is visible as pending in the inventory before it resolves.
- **SC-007**: All trigger types fire through the same supervised run path; no path bypasses the gate, credential injection, or spend metering (verified by the existing enforcement checks continuing to apply to event-/message-/approval-fired runs).

## Assumptions

- **No approval timeout in this slice**: A held action persists until explicitly approved or denied; automatic expiry of pending approvals is out of scope and deferred. (The manifest schema is extended only if approval semantics genuinely require a new field; a timeout, if ever added, is a later increment.)
- **Reuse existing manifest trigger schema**: The `time` / `event {name}` / `message` trigger shapes already parsed are reused as-is. New fields are added only where event/approval semantics genuinely require them, and any addition is justified at plan time.
- **Reuse existing pending-action mechanism**: Approval builds on the gate's existing "parked" action disposition and the substrate-side pending-action store, rather than introducing a parallel mechanism.
- **Single-operator, trusted intake**: The operator-via-chat sender and the event/approval intake are trusted substrate-side channels in this milestone; multi-tenant sender authentication is out of scope. What is in scope is that these channels are distinct from — and unreachable by — untrusted agent-read input and agent output.
- **Out of scope**: the generation pipeline (Phase 4); world-B hostile-agent verification (plan 03-06); any change to connector grants or to spend metering (plans 005/006, already complete and unchanged here).

## Dependencies

- Builds on the time-trigger and supervised run path from Phase 1 (Scheduler → Provisioner → RunSupervisor).
- Builds on the deterministic gate's action partitioning, including the existing "parked / pending-approval" disposition.
- Must preserve the manifest-enforcement, credential-proxy, and spend-metering invariants already established in Phase 3 (plans 03-01 through 03-04a).
