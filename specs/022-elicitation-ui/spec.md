# Feature Specification: Interactive Elicitation UI

**Feature Branch**: `022-elicitation-ui`  
**Created**: 2026-07-01  
**Status**: Draft  
**Input**: User description: "Implement roadmap plan 06-01 — Interactive Elicitation UI: a Phoenix/LiveView conversational workspace that drives the existing elicitation orchestrator from a browser instead of the terminal."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Landing & Session Initiation (Priority: P1)

The user lands on the web interface, views the introductory card, inputs the initial purpose of their agent, and clicks start. The system starts the session backend and displays the elicitor's first question.

**Why this priority**: Core entry point to the system. Necessary for any interaction to happen.

**Independent Test**: Can be tested by visiting the root URL, entering a purpose, and asserting the conversational interface displays with the elicitor's first question.

**Acceptance Scenarios**:
1. **Given** a user is on the root path, **When** they enter a purpose "Monitor Shopify store" and click "Start", **Then** an `ElicitationSession` GenServer starts, and the chat UI loads with the first question.

---

### User Story 2 - Elicitation Turn Loop & Live Spec (Priority: P1)

The user answers the elicitor's questions in a chat interface. The running transcript remains scrollable, and a sidebar displays the drafted specification (purpose, capabilities, boundaries, spend limits) updating in real-time as the intent is clarified.

**Why this priority**: Primary flow for interactive specification drafting.

**Independent Test**: Can be tested by sending a message, checking that it is added to the chat log, and asserting the sidebar fields update accordingly.

**Acceptance Scenarios**:
1. **Given** an active session, **When** the user sends "Yes, it should email me", **Then** the transcript updates with the user message, the elicitor's next question appears, and the capabilities section in the sidebar is populated.

---

### User Story 3 - KISS Scope Creep Warning (Priority: P2)

When a user proposes an action that expands the scope overly, the elicitor returns a scope creep warning. The UI surfaces this warning as an alert banner without blocking the turn loop.

**Why this priority**: Ensures the user is warned about complexity creep.

**Independent Test**: Can be tested by typing a feature-heavy sentence, verifying that the warning banner renders, and that the text input remains interactive.

**Acceptance Scenarios**:
1. **Given** an active session, **When** the user sends a scope-creeping response, **Then** the UI displays the warning box with the pushback message above the input field.

---

### User Story 4 - Spec Confirmation & Persistence (Priority: P1)

When the session is confirmed (or next question is empty), the user is prompted to confirm or refine the spec. Confirming saves the specification file locally and stops the GenServer. Refining returns the user to the chat loop.

**Why this priority**: The terminal step that persists the output.

**Independent Test**: Can be tested by clicking "Confirm", and asserting that `elicited_spec.json` is written to `specs/012-elicit-spec/` and the GenServer terminates.

**Acceptance Scenarios**:
1. **Given** a completed spec, **When** the user clicks "Confirm", **Then** the spec file is saved, a success message is shown, and the session is closed.
2. **Given** a completed spec, **When** the user clicks "Refine", **Then** the confirm card disappears, the text input is restored, and the transcript appends a refinement prompt.

### Edge Cases

- **LiveView Disconnect**: What happens when the user closes the browser tab or disconnects? The linked session GenServer MUST be stopped cleanly so that its registered InferenceBroker token is released, preventing memory/spend registration leaks.
- **Port/Elicitor Crashes**: How does the system handle Python elicitor crashes? The GenServer should capture failures and surface clean error notifications to the user without crashing the web page.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST render a landing form to accept the initial purpose when no session is active.
- **FR-002**: System MUST start the backend `ElicitationSession` GenServer using the submitted purpose.
- **FR-003**: System MUST render a chat interface displaying user and assistant messages chronologically.
- **FR-004**: System MUST render a sidebar displaying the live draft specification dynamically.
- **FR-005**: System MUST render a scope creep warning banner if the GenServer detects scope creep.
- **FR-006**: System MUST show a confirmation state prompting the user to either write the spec or continue refining when the elicitor is done.
- **FR-007**: System MUST write the confirmed spec to `specs/012-elicit-spec/elicited_spec.json` and save the conversation session log to `data/elicitation/`.
- **FR-008**: System MUST monitor and terminate the session GenServer cleanly when the LiveView connection terminates.

### Key Entities

- **ElicitationSession**: The GenServer running the BEAM port and maintaining conversation state.
- **ConversationSession**: The data structure tracking session ID, transcript, spec draft, and status.
- **ElicitedSpec**: The draft spec data structure including purpose, capabilities, boundaries, and spend limits.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can interactively converse with the elicitation orchestrator through the browser interface and reach a written spec file identical to the one produced by the CLI.
- **SC-002**: Disconnected LiveView sockets result in the corresponding GenServer PID terminating within 1 second.
- **SC-003**: The live spec updates in the sidebar within 200ms of the elicitor's turn completion.

## Assumptions

- The existing `AgentOS.ElicitationSession` module runs correctly and provides complete and accurate JSON responses when driven via calls.
- The web application will run on port 4000 locally in the host substrate.
- Browser assets (JS/CSS) do not require a build step and can be served directly.
