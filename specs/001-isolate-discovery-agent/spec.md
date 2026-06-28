# Feature Specification: Isolate the Discovery Agent

**Feature Branch**: `001-isolate-discovery-agent`
**Created**: 2026-06-28
**Status**: Draft
**Input**: User description: "Isolate the discovery agent so it is safe to leave running unattended against the live web, and make it something I can run as part of my daily routine."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run the agent isolated from the host (Priority: P1)

The operator leaves the discovery agent running on its daily trigger, trusting that even
if the agent misbehaves or is compromised, it cannot reach host resources, credentials,
or substrate state beyond what it was explicitly granted.

**Why this priority**: Isolation is the foundational safety property that makes
everything else in this phase meaningful — without it, neither untrusted input nor
unattended operation is safe. It is the smallest slice that delivers standalone value:
the agent that previously ran in the host's trust context now runs contained.

**Independent Test**: Run the discovery agent through its normal trigger and confirm,
from outside the agent, that it executes inside an isolated boundary and that attempts to
read or write host paths, environment, or substrate state outside its granted
inputs/outputs fail.

**Acceptance Scenarios**:

1. **Given** the agent is provisioned, **When** it runs, **Then** it executes inside an
   isolated sandbox separate from the host process and filesystem.
2. **Given** its granted inputs (a snapshot of its mounted state) and a granted output
   action, **When** the agent runs, **Then** it can read its input and emit its output but
   cannot access host resources outside those grants.
3. **Given** the agent attempts to access a resource it was not granted, **When** that
   access occurs, **Then** it is denied or unavailable rather than silently succeeding.

---

### User Story 2 - Safe against hostile web input (Priority: P2)

The operator points the agent at real, untrusted web content (e.g. bookmarked posts). A
poisoned or malformed item must not let the agent break isolation, exfiltrate data, or
corrupt substrate state.

**Why this priority**: This is what makes it safe to run against the LIVE web rather than
hand-fed input — the defining promise of v1. It depends on User Story 1's boundary
existing.

**Independent Test**: Feed the agent a crafted hostile item (prompt-injection text and a
malformed payload) and confirm it neither escapes the sandbox, mutates state outside its
grants, nor leaks data; the run completes or fails safely and legibly.

**Acceptance Scenarios**:

1. **Given** an item containing prompt-injection instructions, **When** the agent
   processes it, **Then** the agent's granted capabilities are unchanged and no
   out-of-grant action occurs.
2. **Given** a malformed or oversized payload, **When** the agent ingests it, **Then**
   the input is sanitized/validated and the run fails safely (and is logged) rather than
   crashing the host or corrupting state.

---

### User Story 3 - Failures surface cleanly and operation stays legible (Priority: P3)

When the isolated child crashes or is OOM-killed, that surfaces to its BEAM supervisor as
a clean process exit so let-it-crash and restart-once-and-alert keep working; and the
operator can read what happened — including failures — from the run-log and standing
inventory without asking the agent.

**Why this priority**: Without clean failure semantics and legibility, unattended daily
operation is unsafe to trust. Builds on User Story 1.

**Independent Test**: Force the isolated child to crash, and separately to exceed memory;
confirm the supervisor observes a clean exit, restart-once-and-alert fires, and the
run-log/inventory record the failure legibly.

**Acceptance Scenarios**:

1. **Given** the child crashes mid-run, **When** the supervisor observes it, **Then** it
   sees a clean process exit (not a hung or zombie boundary) and applies
   restart-once-and-alert.
2. **Given** the child exceeds its memory limit, **When** it is OOM-killed, **Then** that
   surfaces as a clean exit with a logged cause.
3. **Given** any run (success or failure), **When** the operator reads the run-log and
   inventory, **Then** the outcome is visible there without querying the agent.

---

### Edge Cases

- The child produces partial output and then crashes — what is recorded, and is state
  left consistent?
- The sandbox fails to start at trigger time (image/mechanism unavailable) — does this
  surface as a clean, alerted failure?
- An untrusted item is well-formed but adversarial (valid shape, hostile content).
- The child crashes repeatedly — restart-once means the second failure alerts rather than
  loops.
- The daily timer fires while a previous run is still executing in the sandbox.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The discovery agent MUST run inside an isolation boundary separate from the
  host, such that the agent cannot access host resources, credentials, or substrate state
  beyond explicitly granted inputs and outputs.
- **FR-002**: The system MUST pass the agent only its granted inputs — a snapshot of its
  mounted state plus the sanitized untrusted items — and accept only its granted output
  actions across the isolation boundary. Mount and action names come from the agent's
  manifest; the substrate stays agent-agnostic (it does not hard-code any one agent's
  vocabulary).
- **FR-003**: The system MUST sanitize and validate untrusted web input before the agent
  reasons over it, such that injected instructions or malformed payloads cannot cause
  out-of-grant behavior, state corruption, or data exfiltration.
- **FR-004**: A crash or out-of-memory termination of the isolated child MUST surface to
  its BEAM supervisor as a clean process exit.
- **FR-005**: The existing restart-once-and-alert supervision MUST continue to function
  across the isolation boundary.
- **FR-006**: Every run — including failures and their cause — MUST be recorded legibly in
  the run-log and reflected in the standing inventory, readable without querying the
  agent.
- **FR-007**: The agent MUST remain runnable on its existing daily trigger without manual
  supervision between runs.
- **FR-008**: The isolation boundary MUST run the agent with **no network access** (network
  disabled), a read-only host filesystem except a dedicated scratch directory, and explicit
  CPU and memory caps. (No egress is needed this phase — the agent's reasoning is a
  deterministic stub with no outbound calls. An egress allowlist for a real LLM endpoint is
  deferred to the phase that wires the model.)
- **FR-009**: The agent MUST process untrusted content from X/Twitter bookmarks as the
  first in-scope source, supplied as a list of items where each item carries an id, an
  author, text, and any associated URLs.
- **FR-010**: The agent MUST be operable both on its existing daily 07:00 timer
  (unattended) and via an on-demand manual run the operator can trigger ad hoc.

### Key Entities

- **Untrusted Web Item**: a single bookmarked X/Twitter post the agent reasons over.
  Attributes: id, author, text, associated URLs (raw form); plus its sanitized form.
- **Isolation Boundary**: the sandbox separating an agent run from the host. Attributes:
  granted inputs, granted outputs, resource limits.
- **Run Record**: the legible record of one invocation. Attributes: trigger, outcome
  (success/failure), failure cause, timestamp.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A compromised or misbehaving agent cannot access any host resource or
  substrate state outside its granted input/output — verified by attempted out-of-grant
  access being denied in 100% of test cases.
- **SC-002**: A crafted hostile item (prompt-injection plus malformed payload) results in
  zero isolation escapes, zero out-of-grant state mutations, and zero data exfiltrations
  across the hostile-input test set.
- **SC-003**: 100% of child crashes and OOM terminations are observed by the supervisor as
  clean exits, with restart-once-and-alert firing as specified.
- **SC-004**: After any run, the operator can determine what the agent did, whether it
  failed, and why, solely from the run-log and inventory — no agent query needed.
- **SC-005**: The operator can leave the agent running across consecutive daily triggers
  with no manual intervention required between runs.
- **SC-006**: The operator can trigger an on-demand run at any time and observe its
  outcome in the run-log and inventory.

## Assumptions

- Phase 1's port boundary, single-writer state store, daily timer, run-log, standing
  inventory, and restart-once-and-alert supervision are in place and reused.
- The agent's discovery and ranking logic is unchanged in this phase.
- Manifest enforcement, the credential proxy, and spend metering / kill-on-breach are
  explicitly out of scope (Phase 3 / v2).
- The operator's environment can run the chosen isolation mechanism.
- A single discovery agent is in scope; isolating multiple concurrent agents is not
  required yet.
