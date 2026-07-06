# Feature Specification: discord-notify

**Feature Branch**: `034-discord-notify`  
**Created**: 2026-07-06  
**Status**: Draft  
**Input**: User description: "Add discord_notify, the first connector whose execute/2 actually crosses the network — a live Discord incoming-webhook POST..."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Live Notification Egress (Priority: P1)

As a substrate component (such as the Priorities Coach agent), I want to send a real text notification to a Discord channel via an incoming webhook without holding the webhook URL myself, so that I can alert the human operator about important events.

**Why this priority**: This is the core functionality. It is the first connector to perform a real outbound network call, proving the live-egress path works.

**Independent Test**: Configure the system with a test transport. Propose a `notify` action containing test text, and verify that the transport receives a correctly shaped request to the injected webhook URL.

**Acceptance Scenarios**:

1. **Given** a valid webhook credential injected by the substrate, **When** the connector is executed with a `notify` action and valid text, **Then** a notification is delivered to the configured Discord channel.
2. **Given** the test transport is active, **When** the connector is executed, **Then** no actual network call is made to Discord, but the correct payload is captured and validated by the test suite.

---

### User Story 2 - Loud Failure on Delivery Errors (Priority: P1)

As a system operator, I want the connector to fail loudly and return an explicit error if the Discord delivery fails, so that I know exactly when a notification was not delivered.

**Why this priority**: Ensures the system never swallows a success or failure, maintaining operational observability.

**Independent Test**: Configure the test transport to simulate a network or delivery failure. Execute the connector and verify it returns an explicit error payload.

**Acceptance Scenarios**:

1. **Given** the Discord webhook refuses the request (e.g., rate limit or bad token), **When** the connector executes, **Then** it returns an explicit error response.
2. **Given** a network timeout occurs during delivery, **When** the connector executes, **Then** it returns an explicit error response.

---

## Edge Cases

- **Invalid Action/Method**: What happens if an agent proposes an action other than `notify`? (The connector returns an `unknown_method` error).
- **Missing or Invalid Credential**: What happens if the credential injected is empty or malformed? (The request fails and the error is returned to the caller).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a `discord_notify` connector capability.
- **FR-002**: The connector MUST be auto-discovered by the system without manual centralized edits.
- **FR-003**: The connector MUST require deployment consent but MUST NOT require per-call runtime approval (fires unattended).
- **FR-004**: The connector MUST declare a static webhook credential id and a non-zero per-call cost.
- **FR-005**: The `notify` action MUST accept message text only, ensuring the agent never observes the webhook URL or channel ID.
- **FR-006**: The connector MUST format and transmit the notification payload according to the Discord webhook API format.
- **FR-007**: The connector MUST bubble up delivery failures or transport errors as explicit error returns.
- **FR-008**: The system MUST record the outbound notification and its outcome so humans can verify what was sent.
- **FR-009**: The connector MUST be categorized as an external mutating egress capability.
- **FR-010**: The connector MUST support an injectable testing mechanism to enable deterministic validation without a live network connection.

### Key Entities *(include if feature involves data)*

- **discord_notify Connector**: The component providing the capability to send Discord notifications.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The system successfully delivers real notifications to the configured Discord channel in a production environment.
- **SC-002**: The system discovers the new capability automatically with the correct consent, cost, and credential requirements.
- **SC-003**: All network delivery failures are explicitly reported as errors.
- **SC-004**: The test suite validates the notification logic and failure handling without making live network connections.

## Assumptions

- The existing outbound content checking path will correctly sanitize and route the message without modification.
- Multi-channel fan-out, threaded replies, and automatic retries are out of scope.
- A standard HTTP client is available in the environment to make the network request.
