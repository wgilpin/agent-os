# Feature Specification: Manifest Enforcement (v2)

**Feature Branch**: `002-manifest-enforcement`
**Created**: 2026-06-28
**Status**: Draft
**Input**: User description: "Manifest Enforcement (v2): make the deterministic gate a real safety boundary. The hand-written manifest stops being advisory documentation and becomes the enforced contract: the substrate provisions from it, and a deterministic gate — running in the BEAM control plane, OUTSIDE the agent/container — validates every proposed action against the manifest's enumerated grants and constraints before the existing effector acts. The bar for done is world B: the gate physically prevents any manifest breach regardless of what the agent code does or proposes."

## Clarifications

### Session 2026-06-28

- Q: How should "spend" be metered for the deterministic stub? → A: Per-action cost declared in the manifest — each granted action type carries a cost; the meter sums the cost of executed actions against the cap.
- Q: Is the spend `window` fixed or rolling? → A: Fixed (resetting) window — spend accumulates within a period and resets to zero at the boundary.
- Q: What values does `on_breach` accept in v2? → A: `kill` only — a real kill that stops the run; the schema may extend later but only `kill` is implemented and tested now.
- Q: Which actions require approval? → A: Manifest per-grant — a grant declares `requires_approval` in its constraints; approval is park-and-resume (the action is held pending in substrate state and a later approval event drives it through the gate).
- Q: How do event/message triggers enter the substrate? → A: In-BEAM messages to a substrate process — an event or operator message is a message send; tests and a thin CLI emit them. No external network surface this phase.
- Refinement (supersedes Q4 placement, same intent): `requires_approval` — and per-action `cost` and `credential` — are intrinsic to the **connector** (a substrate capability registry), not per-grant manifest fields. The manifest grant carries only `{connector, recipients, methods}` scope. Rationale: a manifest author (human now, machine in v3) must not be able to downgrade a dangerous connector's approval/credential; this also de-leaks the Effector's hard-coded action names (Principle IX). The approval *behaviour* (park-and-resume) is unchanged. See FR-002a and `contracts/connector-registry.md`.

## User Scenarios & Testing *(mandatory)*

The "user" of this feature is the human operator who declares and runs the (still
hand-written) discovery agent, plus the substrate itself which must enforce that
declaration. The agent is the untrusted party — never a beneficiary of trust.

### User Story 1 - Every action is checked against the declared envelope (Priority: P1)

The operator declares, in the manifest, exactly which connectors/mounts the agent may
use and — per grant — which recipients and methods are in scope. When the agent proposes
an action, the substrate validates it against that declared envelope *before* the
privileged effector runs. Anything outside the envelope is rejected and never acted on.

**Why this priority**: This is the core of v2 — the gate becoming a real boundary. Without
it, nothing else in the phase matters. It is the hard dependency of all generation work.

**Independent Test**: Feed the gate a manifest with one granted action scoped to a
specific recipient/method, then submit (a) an in-scope action and (b) several out-of-scope
actions (wrong recipient, wrong method, ungranted connector). Assert the in-scope one
passes to the effector and each out-of-scope one is rejected with a logged reason — using
the deterministic stub agent, no live model.

**Acceptance Scenarios**:

1. **Given** a manifest granting an action to recipient R via method M, **When** the agent
   proposes that action to recipient R via method M within cap, **Then** the gate approves
   it and the effector executes it on the agent's behalf.
2. **Given** the same manifest, **When** the agent proposes the action to a recipient other
   than R, **Then** the gate rejects it, the effector never runs, and the rejection is
   logged with the failing constraint.
3. **Given** the same manifest, **When** the agent proposes an action using an ungranted
   connector or method, **Then** the gate rejects it before any effector call.
4. **Given** recipient/method scoping, **When** a reviewer inspects where the scope is
   defined, **Then** it is read from the manifest, not hard-coded in the gate logic.

---

### User Story 2 - The manifest is invisible to the agent (Priority: P1)

The manifest is privileged-read for the gate only. The agent (the code running in the
container) cannot read it: it is never mounted into the container nor serialized into the
data sent across the port boundary. The agent receives only its sanitized input and the
schema of actions it may propose.

**Why this priority**: No-ambient-authority and gate-is-the-only-firewall both require the
untrusted party to be unable to see the contract it is bound by. A manifest the agent can
read is a manifest the agent can reason around.

**Independent Test**: Inspect the exact bytes crossing the port boundary and the container
mount set for a run; assert the manifest content (grants, caps, constraints) appears in
neither.

**Acceptance Scenarios**:

1. **Given** a configured agent, **When** a run is invoked, **Then** the manifest file is
   not among the container's mounts and its contents are absent from the boundary payload.
2. **Given** a run, **When** the agent emits proposed actions, **Then** it does so against a
   published action schema, having never been handed the grants/caps/constraints.

---

### User Story 3 - No LLM-running component holds a mutating credential (Priority: P1)

A credential proxy in the control plane holds the capabilities (secrets/tokens) and
injects the credential only at the deterministic chokepoint, at action time, after the
gate has approved. The agent process never receives a credential that can mutate external
state. Any inference-only credential (a read-only model key) is held separately from
mutating ones.

**Why this priority**: This is the structural guarantee behind the gate — even a fully
compromised agent cannot act, because it never holds the means to act. It is constitution
Principle XI made real.

**Independent Test**: Inspect the agent's environment and boundary payload for any mutating
credential; assert none is present. Drive an approved action and confirm the credential is
present only inside the chokepoint at injection time.

**Acceptance Scenarios**:

1. **Given** an approved action, **When** the effector executes it, **Then** the credential
   is injected by the proxy at the chokepoint and is never exposed to the agent process.
2. **Given** any run, **When** the agent's environment/inputs are inspected, **Then** no
   mutating credential is present anywhere the agent can read.

---

### User Story 4 - Spend is capped, metered, visible, and breach kills the run (Priority: P2)

Each agent's manifest declares spend as `{cap, window, on_breach}`. Spend is metered at the
chokepoint, attributable per agent and visible to the operator. When spend would exceed the
cap within the window, the declared `on_breach` action fires — at minimum a real kill that
stops the run (not just a logged warning), and the kill does not trigger the Phase 1
restart-once-and-alert (it is an intentional stop, not a crash).

**Why this priority**: Spend is the third axis of the envelope alongside recipient and
method. It is essential to "v2 done" but builds on the gate (US1) and chokepoint (US3).

**Independent Test**: With a small cap, drive actions until the meter would exceed it;
assert the action at the cap boundary is allowed, the action over it is killed per
`on_breach`, the spend is visible per agent, and no restart is attempted.

**Acceptance Scenarios**:

1. **Given** a cap of N over window W, **When** cumulative spend within W reaches N, **Then**
   the next over-cap action is blocked and `on_breach` (kill) fires.
2. **Given** a breach-triggered kill, **When** the supervisor observes the stop, **Then** it
   is treated as intentional and restart-once-and-alert is NOT invoked.
3. **Given** a run, **When** the operator inspects spend, **Then** it is reported per agent
   for the current window.

---

### User Story 5 - Event-triggers and message-triggers fire runs (Priority: P2)

Beyond the Phase 1 daily timer, the substrate can fire an agent run from an event-trigger
and from a message-trigger, both delivered as in-BEAM messages to a substrate process (no
external network surface this phase). Operator approval is modelled as an event-trigger; the
operator, via chat, is just another process emitting a message into the substrate. Approval
is required only for actions on a connector the registry marks `requires_approval`; such actions
are park-and-resume — held pending in substrate state while the run completes, then driven
through the gate by a later approval event.

**Why this priority**: Triggers broaden how runs start and let approval be expressed within
the same model, but the safety boundary (US1–US3) is the load-bearing part of the phase.

**Independent Test**: Emit an event and, separately, a message into the substrate; assert
each fires exactly one run through the same gated pipeline. Model an approval as an event
and assert the awaiting action proceeds only after the approval event arrives.

**Acceptance Scenarios**:

1. **Given** an event-trigger, **When** the event is emitted, **Then** one gated run fires.
2. **Given** a message-trigger, **When** a message is emitted, **Then** one gated run fires.
3. **Given** an action on a `requires_approval` connector parked pending approval, **When**
   the approval event arrives, **Then** the held action proceeds through the gate; absent
   it, the action does not proceed and the run reaches a defined terminal state.

---

### User Story 6 - World B holds against a hostile agent (Priority: P1)

The acceptance bar for the whole phase: a deliberately misbehaving agent cannot breach the
manifest. An adversarial stub agent that proposes an out-of-scope recipient, an over-cap
spend, and an ungranted method is physically blocked by the gate at the chokepoint in every
case — verified by test, not by inspecting a well-behaved run.

**Why this priority**: "World B" is the definition of done for v2 and the hard precondition
for v3 (generation). A gate only tested against a cooperative agent proves nothing.

**Independent Test**: Run the adversarial stub agent variant; assert each hostile proposal
is rejected at the gate and the effector never executes it, with a loud rejection per case.

**Acceptance Scenarios**:

1. **Given** the adversarial stub agent, **When** it proposes an out-of-scope recipient,
   **Then** the gate blocks it and the effector does not run.
2. **Given** the adversarial stub agent, **When** it proposes an over-cap spend, **Then**
   `on_breach` fires and the action does not execute.
3. **Given** the adversarial stub agent, **When** it proposes an ungranted method/connector,
   **Then** the gate blocks it before the effector.

---

### Edge Cases

- **Malformed manifest**: a manifest with an unparseable or missing constraints sub-block
  fails loudly at provisioning — the agent is not provisioned rather than provisioned with
  an empty (deny-all or, worse, allow-all) envelope.
- **Action with no matching grant**: rejected (default-deny), not ignored silently.
- **Spend exactly at the cap boundary**: with summed per-action cost, an action whose cost
  lands cumulative spend exactly at the cap is allowed; the next action over the cap is
  blocked (boundary behaviour stated explicitly so it is testable).
- **Window rollover**: spend is a fixed window — cumulative cost resets to zero at the
  period boundary; an action blocked late in one window is permitted again after the reset.
- **Approval never arrives**: a parked `requires_approval` action does not execute; because
  approval is park-and-resume (no blocking process), the run reaches its terminal state and
  the action simply stays pending rather than hanging a process indefinitely.
- **Breach kill vs. genuine crash**: the supervisor must distinguish an intentional
  on_breach kill from a real child crash so restart-once-and-alert applies only to the
  latter.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The substrate MUST provision each agent from its manifest as the enforced
  contract, loading the enumerated grants and their per-grant scope sub-block (recipients/methods).
- **FR-002**: The manifest MUST carry a per-grant scope sub-block in which each grant declares its
  connector and its recipient/method scope; the gate MUST read scope from the manifest, not from
  values hard-coded in the gate. Per-action cost, approval-requirement, and credential are
  intrinsic to the connector (a substrate capability registry), NOT author-set in the manifest,
  so a manifest author cannot downgrade a connector's danger (see FR-002a).
- **FR-002a**: The substrate MUST maintain a connector capability registry that fixes each
  connector's intrinsic danger — whether it mutates external state, whether it requires approval,
  which credential it needs, and its per-action cost. Connectors MUST be generic capabilities
  (not agent-specific names), and the registry — not the manifest — MUST be the source of these
  values. A manifest granting a connector absent from the registry MUST fail provisioning loudly.
- **FR-003**: The deterministic gate MUST validate every action the agent proposes against
  {granted connector, recipient scope, method scope, spend} and MUST reject any action outside
  the declared envelope before the effector runs (default-deny). (Mount access governs state
  reads and is enforced at provisioning, not in the per-action gate.)
- **FR-004**: The gate MUST run in the BEAM control plane, outside the agent/container, and
  MUST sit in front of the existing Phase 1 effector chokepoint.
- **FR-005**: Every gate rejection MUST be logged with the specific failing constraint
  (loud failure, no silent denial).
- **FR-006**: The manifest MUST be privileged-read for the gate only and MUST NOT be
  readable by the agent — not mounted into the container and not serialized into the
  port-boundary payload.
- **FR-007**: The agent MUST receive only its sanitized input and a published action schema;
  it MUST NOT receive grants, caps, or constraints.
- **FR-008**: A credential proxy MUST hold capabilities and inject the credential at the
  deterministic chokepoint at action time, only after gate approval.
- **FR-009**: No LLM-running component (the agent/container) MUST ever hold a mutating
  credential; any inference-only credential MUST be held separately from mutating ones.
- **FR-010**: The manifest MUST express spend as `{cap, window, on_breach}` per agent, where
  `cap` is a number, `window` is a fixed (resetting) period, and `on_breach` is `kill` in
  v2 (the value set MAY extend in a later phase; only `kill` is implemented now).
- **FR-010a**: Each connector MUST declare its per-action cost in the capability registry (not
  the manifest); the meter computes spend as the sum of executed actions' connector costs against
  the cap.
- **FR-011**: Spend MUST be metered at the chokepoint and attributable/visible per agent for
  the current fixed window, and MUST reset to zero at the window boundary.
- **FR-012**: A spend breach MUST trigger the declared `on_breach` (`kill` in v2), a real
  kill that stops the run (not merely a logged warning).
- **FR-013**: An on_breach kill MUST be treated as an intentional stop and MUST NOT trigger
  the Phase 1 restart-once-and-alert policy.
- **FR-014**: The substrate MUST support firing a run from an event-trigger and from a
  message-trigger — both delivered as in-BEAM messages to a substrate process (no external
  network surface this phase) — in addition to the existing daily timer.
- **FR-015**: Operator approval MUST be modelled as an event-trigger and required only for
  actions on a connector the registry marks `requires_approval` (FR-002a). Such an action MUST be
  parked pending in substrate state (the run completes) and MUST proceed only after the approval
  event arrives (park-and-resume; no blocking process).
- **FR-016**: A malformed or missing constraints sub-block MUST fail provisioning loudly;
  the agent MUST NOT be provisioned with an undefined envelope.
- **FR-017**: The phase MUST include an adversarial stub-agent test proving the gate blocks
  an out-of-scope recipient, an over-cap spend, and an ungranted method (world-B
  verification), with the effector never executing the blocked action.

### Key Entities *(include if feature involves data)*

- **Manifest**: the declarative source of truth for *what this agent may do and to whom*. Carries
  purpose, enumerated grants (connector + recipient/method scope), mounts, spend `{cap, window,
  on_breach}` where `window` is a fixed period and `on_breach` is `kill`, and triggers.
  Privileged-read for the gate only. Does NOT carry connector danger (cost/approval/credential).
- **Grant**: an authorization for the agent to use one connector, scoped to recipients and
  methods. The unit the gate matches a proposed action against. Scope only — no intrinsic-danger
  fields.
- **Connector Capability (registry)**: the substrate's source of truth for *how dangerous a
  capability is* — `mutating?`, `requires_approval?`, `credential`, and per-action `cost` — keyed
  by a generic connector name. Not author-controllable from the manifest.
- **Proposed Action**: an action the agent emits for consideration — connector/method,
  recipient, and any spend impact. Validated, never trusted.
- **Gate Decision**: the deterministic approve/reject outcome for a proposed action, with
  the matched grant (on approve) or the failing constraint (on reject), logged either way.
- **Credential Proxy**: the control-plane holder of capabilities that injects a credential
  at the chokepoint at action time; the agent never sees mutating credentials.
- **Spend Ledger**: per-agent metered spend — the summed connector cost of executed actions —
  over the current fixed window, used to enforce the cap and reported to the operator; resets
  at the window boundary.
- **Trigger**: the cause of a run — timer (existing), event, or message; approval is an
  event-trigger.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of proposed actions are evaluated by the gate before any effector
  execution; no action path bypasses the gate.
- **SC-002**: For a manifest with recipient/method/connector scoping, every out-of-scope
  proposal (wrong recipient, wrong method, ungranted connector) is rejected and never
  executed — demonstrated across all three categories.
- **SC-003**: The manifest's grants, caps, and constraints appear in neither the container
  mount set nor the port-boundary payload for any run.
- **SC-004**: No mutating credential is present in the agent's environment or inputs in any
  run; an approved action still executes via chokepoint injection.
- **SC-005**: With a spend cap of N over a fixed window W and per-action costs declared in
  the manifest, the action whose summed cost lands at N is allowed and the first action over
  N is killed per `on_breach`; per-agent summed spend for the window is inspectable by the
  operator and resets at the window boundary.
- **SC-006**: A breach-triggered kill does not cause a restart; a genuine child crash still
  does (restart-once-and-alert preserved).
- **SC-007**: An event-trigger and a message-trigger each fire exactly one gated run; an
  approval-gated action proceeds only after its approval event.
- **SC-008**: The adversarial stub agent is blocked in all three breach categories with the
  effector never executing — world B verified by an automated test, not manual inspection.

## Assumptions

- The discovery agent remains hand-written this phase; no agent generation/synthesis is in
  scope (that is Phase 4 / v3, hard-gated behind this phase per constitution Principle XII).
- No LLM-authored manifests, no security-review agent, and no conformance-auditor are built
  here.
- Agent reasoning may remain a deterministic stub wherever a live model is not required, so
  every test is deterministic with no live remote dependency (constitution Principle IV).
- The existing Phase 1 effector chokepoint and Phase 2 container/port boundary are reused as
  the integration seam; the gate is added in front of the effector rather than replacing it.
- Spend is metered as the sum of per-action costs declared in the manifest, against a numeric
  cap over a fixed (resetting) window; `on_breach` is `kill` in v2 (resolved in Clarifications).
- Event/message triggers are delivered as in-BEAM messages to a substrate process (no external
  surface this phase); approval is park-and-resume and required only for `requires_approval`
  grants (resolved in Clarifications).
- Single agent, one manifest; concurrent multi-agent enforcement is not a goal this phase.

## Dependencies

- **Phase 1 (Walking Skeleton)**: manifest parser, single-writer state store, effector
  chokepoint, run-log/inventory, restart-once-and-alert — all reused.
- **Phase 2 (Isolation)**: containerised agent across the port boundary, input sanitization —
  the boundary the manifest must NOT cross.
- **Constitution v1.2.0**: Principles X (No Ambient Authority), XI (Gate Is the Only
  Firewall), XII (Enforcement Precedes Generation) are the locked invariants this phase
  makes real.
