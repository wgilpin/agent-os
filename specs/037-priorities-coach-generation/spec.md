# Feature Specification: Priorities Coach E2E Generation

**Feature Branch**: `[037-priorities-coach-generation]`  
**Created**: 2026-07-06  
**Status**: Draft  
**Input**: User description: "Generate, deploy, and live-smoke the Priorities Coach through the unchanged six-stage pipeline, proving world-B holds against the machine-written agent with the new grant shapes from 10-01..10-03."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Pipeline Orchestration (Priority: P1)

As an operator, I want the orchestrator to process the Priorities Coach purpose into a machine-written manifest, judge, and agent body, and pass security review to auto-deploy, so that the end-to-end pipeline is proven for a complex real-world agent.

**Why this priority**: Proving that the orchestrator and manifest projection can successfully emit the new grant shapes (path grants for local files, static discord notify credentials, and composite message+time triggers) is the core technical goal of this phase.

**Independent Test**: Can be tested by running the generation pipeline (e.g., via the E2E generation thread script) on the coach's purpose prompt, verifying that the generated manifest includes the expected grants and triggers, and that it successfully deploys. No live network or live Docker needed for generation tests.

**Acceptance Scenarios**:

1. **Given** the Priorities Coach purpose prompt, **When** the generation pipeline runs, **Then** a manifest is projected containing `file_read`/`file_write` (path grant), `discord_notify` (static credential), and `%{type: :message}` + time triggers, alongside a spend cap.
2. **Given** the generated manifest, judge, and body, **When** they undergo security review, **Then** they pass and automatically deploy.

---

### User Story 2 - World-B Consistency Validation (Priority: P1)

As a security engineer, I want the world-B test battery to pass against the generated coach's manifest, so that I have confidence the new grant shapes (path, notify, triggers) are enforced properly by the gate without breaking existing security guarantees.

**Why this priority**: Ensures that adding these new capabilities hasn't relaxed any invariant (e.g. ambient authority, ungranted action rejections).

**Independent Test**: Can be tested by running the `world_b_generated_test.exs` suite against the coach's generated manifest.

**Acceptance Scenarios**:

1. **Given** the coach's generated manifest and the world-B suite, **When** the suite runs, **Then** all BC-* breach cases hold (e.g. ungranted actions are rejected).

---

### User Story 3 - Live Smoke Execution (Priority: P2)

As a user, I want the deployed Priorities Coach to successfully execute its full daily loop, so that I can see the live agent read my priorities, ping me on Discord, wait for a reply, and write back to the doc.

**Why this priority**: This validates the live, end-to-end functionality of all the connectors built in 10-01..10-03 working in concert.

**Independent Test**: Can be fully tested manually by waiting for the 0800 time trigger or invoking it, and observing the real Discord channel and local file.

**Acceptance Scenarios**:

1. **Given** a deployed Priorities Coach, **When** its scheduled trigger fires, **Then** it reads the real local priorities document.
2. **Given** the read context, **When** it asks a question, **Then** it sends a real message to the Discord channel via `discord_notify`.
3. **Given** a user reply on Discord, **When** the Discord ingress receives it, **Then** it raises a message trigger, the coach processes it, and successfully writes back to the local priorities document.

### Edge Cases

- What happens if the orchestrator fails to project both the message trigger and the time trigger into the manifest? (Pipeline fails at generation, manual fix required in projection logic).
- How does the system handle if the user never replies on Discord? (The agent just sits idle; the time trigger will fire again next day).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The manifest projection MUST support emitting a path grant for `file_read` and `file_write`.
- **FR-002**: The manifest projection MUST support emitting a static credential for `discord_notify`.
- **FR-003**: The manifest projection MUST support emitting multiple triggers for a single agent (a time trigger and a message trigger).
- **FR-004**: The orchestrator MUST run the coach purpose through elicit, projection, judge, body generation, and security review without manual intervention.
- **FR-005**: The world-B test suite MUST successfully parse and run against the coach's manifest, enforcing all new grant types.

### Key Entities

- **Priorities Coach**: The generated agent instance encompassing the manifest, judge, and body.
- **PipelineRun**: The record of the generation pipeline execution, logging provenance and verdicts.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of the world-B breach cases (BC-*) pass against the machine-written coach manifest.
- **SC-002**: Generation and orchestration tests pass with zero live network calls and zero Docker dependencies.
- **SC-003**: The manual live smoke completes the full 6-step loop (trigger -> read -> ping -> reply -> ingest -> write) successfully on a deployed agent.
- **SC-004**: Zero changes required to `Gate`, the envelope predicate, or review-mode semantics during this generation.

## Assumptions

- The new connectors (`discord_notify`, `file_read`, `file_write`, Discord ingress) from 10-01..10-03 have been fully implemented and merged.
- A local priorities document exists and is correctly configured for the path grant.
- A valid Discord webhook URL and bot token are configured as static credentials in the environment.
- The pipeline will successfully infer the spend cap requirement from the coach's nature.
