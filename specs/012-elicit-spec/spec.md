# Feature Specification: Stage 1 Elicit Spec (elicit-spec)

**Feature Branch**: `012-elicit-spec`  
**Created**: 2026-06-30  
**Status**: Draft  
**Input**: User description: "Stage 1 of the v3 six-stage generation pipeline — ELICIT THE SPEC. An orchestrator drives a conversation with a non-coder who declares a purpose in natural language ("reply to recruiter emails", "watch X for mentions of my project"), and questions the user until that purpose is KISS-clear: minimise everything, surface the smallest set of capabilities/connectors/triggers/spend the purpose actually needs, and resolve ambiguity by asking rather than assuming. The output of this stage is a STRUCTURED ELICITED SPEC artifact — the resolved, minimised intent — which is the sole input Stage 2 (04-05, REQ-gen-manifest) consumes to write the manifest. This stage does NOT write the manifest, the judge, the agent body, or any code; it produces the human-confirmed spec only."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prompting purpose and clarifying intent (Priority: P1)

A non-coder starts the orchestrator by entering a high-level goal (e.g., "reply to recruiter emails"). The orchestrator analyzes this, identifies that the user wants to read email and respond, and asks questions to narrow down the source and destination.

**Why this priority**: P1. This is the core purpose of Stage 1: turning a vague user intent into a clear definition of what triggers the agent, what it is allowed to read, what it is allowed to write, and where it is allowed to egress.

**Independent Test**: Run a mock orchestrator conversation where the user inputs "reply to recruiter emails". The system asks a series of clarifying questions. The user provides answers. The system outputs a structured spec containing the minimal required fields.

**Acceptance Scenarios**:

1. **Given** the orchestrator has started, **When** the user enters "reply to recruiter emails", **Then** the system asks specific questions about:
   - What email provider/account to read (data source/connector)
   - What triggers the agent (e.g., new incoming email, cron schedule)
   - What action to take (e.g., save draft, send email)
   - The destination of any outgoing communication
2. **Given** the user has answered the questions, **When** the system compiles the answers, **Then** it generates a structured spec draft detailing the minimised capabilities and boundaries.

---

### User Story 2 - Pushing back on excess capabilities / KISS enforcement (Priority: P2)

The user suggests a broad or risky capability (e.g., "delete spam emails" or "access my entire inbox and send updates to slack"). The orchestrator actively pushes back, pointing out the risk and proposing the minimum scope necessary to achieve the goal (e.g. read-only access and creating drafts instead of direct sends/deletes).

**Why this priority**: P2. Essential for the safety argument (Constitution I Simplicity First, II Explicit Scope Control). Ensuring the smallest capability grant footprint is a first-class output property of the conversation.

**Independent Test**: In a test script, input a prompt asking for full administrator access. The orchestrator must decline to add full access to the spec draft and must recommend a scoped read/write capability instead.

**Acceptance Scenarios**:

1. **Given** the user requests a capability that is broad (e.g., delete files, write-access where read-only is sufficient), **When** the orchestrator evaluates the draft, **Then** the orchestrator informs the user of the security/complexity risk and presents a minimised alternative.
2. **Given** the orchestrator presents the minimised alternative, **When** the user accepts it, **Then** the capability footprint is updated to the smaller set.

---

### User Story 3 - Structured Spec Confirmation (Priority: P1)

Once the specification details are resolved and minimised, the orchestrator presents a structured view of the specification to the user (purpose, capabilities, boundaries, spend) and requires explicit human confirmation.

**Why this priority**: P1. Since Stage 1 is the *only* human-in-the-loop stage in the synthesis pipeline, we must have explicit human confirmation before the spec is written and passed downstream.

**Independent Test**: The system displays the final structured spec draft and blocks until the user enters "yes" or "confirm". If they say "no" or request changes, the system resumes the clarification loop.

**Acceptance Scenarios**:

1. **Given** all spec details are gathered, **When** the orchestrator displays the structured summary (purpose, capability grant, boundary, spend), **Then** it prompts: "Do you confirm this specification? (yes/no)".
2. **Given** the confirmation prompt, **When** the user inputs "yes", **Then** the spec is written to disk with `confirmed: true` and marked as ready for manifest generation.
3. **Given** the confirmation prompt, **When** the user inputs "no" or requests changes, **Then** the system asks how they want to adjust the spec and loops back.

---

### Edge Cases

- **User enters completely invalid or empty purpose**: The orchestrator must handle this by requesting a new purpose and explaining what kinds of goals the system is designed to synthesize.
- **User provides conflicting responses** (e.g., saying "read-only" but later saying "it must delete files"): The orchestrator must detect this conflict, flag it to the user, and ask for resolution.
- **Connection loss / interruption during conversation**: The orchestrator must persist the draft state of the conversation to disk so the user can resume without restarting from scratch.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST drive a conversation with a non-coder user starting from a natural language purpose.
- **FR-002**: The orchestrator MUST be generic and not hardcoded to any specific domain (e.g. discovery agent).
- **FR-003**: The orchestrator MUST identify candidate triggers, data sources, actions, and egress destinations based on the user's input.
- **FR-004**: The orchestrator MUST actively question the user to minimise the capability footprint, suggesting read-only, draft-only, or domain-scoped boundaries instead of wide/unrestricted grants.
- **FR-005**: The orchestrator MUST push back on scope creep, asking the user to justify any capability that is not strictly required for the core purpose.
- **FR-006**: The system MUST output a strongly-typed `STRUCTURED ELICITED SPEC` artifact representing the resolved, minimised intent.
- **FR-007**: The structured spec MUST be represented by a clean, deterministic data structure (e.g., Elixir struct or JSON schema) containing:
  - `purpose`: A brief, clear statement of what the agent does.
  - `capabilities`: An allowlist of specific capability grants (e.g. `read_inbox`, `write_slack`).
  - `boundaries`: Restrictions on where capabilities can act (e.g., specific folders, email senders, or web egress hosts).
  - `spend_limits`: Token budgets or dollar-denominated spend caps.
  - `confirmed`: A boolean indicating explicit human confirmation.
- **FR-008**: The system MUST NOT write the manifest, the judge, the agent body, or any executable code during this stage; it only produces the human-confirmed spec.
- **FR-009**: The system MUST persist the conversation draft state to disk to allow resuming interrupted sessions.

### Key Entities

- **ElicitedSpec**: The strongly-typed output artifact. Key attributes:
  - `purpose` (String)
  - `capabilities` (List of Strings)
  - `boundaries` (Map of target scope to permitted locations/domains)
  - `spend_limits` (Map of limit type to numeric value)
  - `confirmed` (Boolean)
- **ConversationSession**: The active state of the elicitation process. Key attributes:
  - `session_id` (String)
  - `original_purpose` (String)
  - `transcript` (List of messages)
  - `spec_draft` (ElicitedSpec)
  - `pending_clarifications` (List of questions)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of specs consumed by Stage 2 (manifest generation) must have `confirmed: true` set by Stage 1.
- **SC-002**: For standard user prompts (e.g., "watch X for mentions of my project"), the orchestrator successfully reduces the proposed capability set to the absolute minimum (e.g., no write/delete access) in 90% of test runs.
- **SC-003**: The orchestrator prompts the user for confirmation with a clear, human-readable summary of capability grants (reusing the 04-01 deterministic capability render format).
- **SC-004**: Users are able to complete the elicitation flow and confirm their spec in under 6 conversational turns.

## Assumptions

- **A-001**: Elicitation happens via a terminal/chat interface where the user can respond to questions in real time.
- **A-002**: An LLM is used to guide the conversational flow and propose spec fields, but the final output is validated against a schema and requires explicit confirmation.
- **A-003**: Downstream manifest emission (Stage 2) consumes the `ElicitedSpec` directly and maps it deterministically to the manifest file format.
