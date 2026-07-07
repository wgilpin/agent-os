# Feature Specification: Discord Gateway Ingress

**Feature Branch**: `036-discord-ingress`  
**Created**: 2026-07-06  
**Status**: Draft  
**Input**: User description: "Stand up a substrate-supervised Discord ingress that receives the user's reply in the channel and feeds it into the waiting agent's message trigger — the first real external event to enter the substrate."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Receive and Route Valid Messages (Priority: P1)

As a system orchestrator, I want inbound Discord channel messages from the configured user to automatically feed into the waiting agent's message trigger, so that the agent can react to my replies.

**Why this priority**: This is the core capability required for the Priorities Coach agent to receive real human input and continue its task.

**Independent Test**: Can be fully tested by providing a stubbed/mocked websocket connection that injects a message payload from the configured user, verifying it is routed to the trigger gateway.

**Acceptance Scenarios**:

1. **Given** a supervised Discord Gateway connection, **When** a message is received from the configured user in the configured channel, **Then** the message text is extracted and submitted to `TriggerGateway.submit/1` as `{:message, coach_agent, reply_text}`.

---

### User Story 2 - Ignore Unauthorized Messages (Priority: P2)

As a security-conscious orchestrator, I want messages from any other user or channel to be ignored, so that unauthorized users cannot inject signals into the substrate or trigger agents.

**Why this priority**: Security boundary. The agent is only permitted to communicate with the designated owner/user.

**Independent Test**: Can be tested by injecting a mocked websocket message with a non-matching user ID or channel ID and asserting that it is dropped.

**Acceptance Scenarios**:

1. **Given** a supervised Discord Gateway connection, **When** a message is received from a non-configured user, **Then** the message is dropped, loudly logged, and no signal is submitted to the TriggerGateway.
2. **Given** a supervised Discord Gateway connection, **When** a message is received in a non-configured channel, **Then** the message is dropped, loudly logged, and no signal is submitted.

---

### Edge Cases

- What happens when the Discord connection drops or errors? (The supervised component must reconnect with backoff; it must not crash the substrate).
- What happens when the message payload is malformed or lacks text content? (Should be safely ignored/logged).
- What happens if the `TriggerGateway` is unavailable or crashes on submit? (The failure should be contained; the ingress connection should remain alive).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST maintain a persistent Discord Gateway bot connection (websocket) to receive messages.
- **FR-002**: The connection MUST be supervised; crashes or disconnects MUST trigger a reconnect with backoff without taking down the entire substrate.
- **FR-003**: The system MUST authenticate with Discord using a static bot token resolved via `CredentialSource`.
- **FR-004**: The system MUST filter incoming messages, processing only those originating from a specific configured user ID and channel ID.
- **FR-005**: The system MUST extract the free-text content of valid incoming messages.
- **FR-006**: The system MUST submit the extracted content to the existing `TriggerGateway` as a message trigger signal (`{:message, agent, content}`).
- **FR-007**: The system MUST log dropped/unauthorized messages prominently.
- **FR-008**: The substrate MUST NOT implement reply-correlation or run-resume logic; this remains the agent's responsibility.

### Key Entities

- **Discord Gateway Connection**: The long-lived websocket connection to Discord.
- **Inbound Message**: The payload received from Discord, containing author, channel, and content.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of valid inbound test messages are successfully transformed into TriggerGateway signals.
- **SC-002**: 100% of unauthorized messages (wrong user or channel) are dropped and produce no trigger signal.
- **SC-003**: The system automatically recovers from 100% of simulated socket disconnects without a full substrate crash.
- **SC-004**: The bot token is never observable by any agent workload.
- **SC-005**: All acceptance paths can be verified via tests without network access or Docker dependencies.

## Assumptions

- The bot token and configured user/channel IDs are provisioned correctly at admission time.
- The existing `TriggerGateway.submit/1` mechanism works as expected and requires no changes.
- A long-lived websocket (Gateway) is acceptable and preferred over an interactions-endpoint for free-text capabilities.
