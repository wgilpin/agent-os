# Feature Specification: Pluggable Connector Registry

**Feature Branch**: `028-pluggable-connector-registry`  
**Created**: 2026-07-02  
**Status**: Draft  
**Input**: User description: "Plan 08-01: Pluggable connector registry. Make the connector registry extensible so adding a capability is dropping ONE self-contained module into a dedicated connectors folder — no editing of the gate, effector, credential loader, manifest projection, consent render, or any central registration list. This is a substrate refactor that adds NO new connector; it is proven by migrating the four existing connectors onto the new shape with the world-B suite unchanged and green."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Frictionless Capability Addition (Priority: P1)

Developers can add new capabilities or connectors to the system by placing a single, self-contained capability module file in the designated connectors directory. The system automatically registers the connector's metadata and makes it available to the gate and effector without requiring any edits to central registry files or other substrate components.

**Why this priority**: Eliminates code coupling and central list maintenance, allowing the system to scale easily as new capabilities are added.

**Independent Test**: Can be fully tested by creating a temporary/test-only connector module file in the connectors directory and verifying that the system boot process automatically registers it and exposes its capabilities.

**Acceptance Scenarios**:

1. **Given** a new capability module is placed in the designated connectors folder, **When** the substrate boots, **Then** the new capability is automatically available in the registry map with the correct metadata.
2. **Given** the four existing capability modules, **When** they are migrated to the new pluggable folder structure, **Then** the system registry continues to return the identical metadata map to the gate and external clients.

---

### User Story 2 - Generic Post-Approval Credential Injection (Priority: P2)

When an action requiring a secret/credential is executed by the system post-approval, the system dynamically resolves the credential based on the declared ID in the connector's metadata. The credential injection chokepoint is completely generic, resolving the credential from the environment or system configuration without hardcoding specific connector names.

**Why this priority**: Maintains security by keeping credentials out of agent workloads and ensures that any third-party connector can request and receive credentials cleanly.

**Independent Test**: Can be tested by executing a test capability that declares a custom credential ID and validating that the secret value is successfully resolved from the environment and passed to the connector during execution.

**Acceptance Scenarios**:

1. **Given** a connector module declaring a credential ID, **When** its action is executed, **Then** the credential value is dynamically resolved from the system environment/config and injected into the execution chokepoint.
2. **Given** a connector module requiring a credential that is not configured, **When** execution is attempted, **Then** the execution fails closed with a credential error and does not execute the underlying action.

---

### User Story 3 - Fault-Contained Action Execution (Priority: P3)

The execution of each connector capability is strictly isolated. If a connector raises an exception, errors out, or hangs due to external network I/O, the failure is contained at the effector level. The system captures the error, logs it with the connector's name, and fails closed without crashing the main run worker or taking down the substrate.

**Why this priority**: Prevents a single faulty or slow integration from crashing the entire run worker or compromising the operating system substrate.

**Independent Test**: Can be tested by running a connector whose execution raises a runtime exception or blocks infinitely, verifying that the execution terminates safely and returns a fail-closed error.

**Acceptance Scenarios**:

1. **Given** a connector action whose execution raises a runtime error, **When** executed by the effector, **Then** the exception is caught, logged, and a clean error tuple is returned without crashing the process.
2. **Given** a connector action whose execution blocks/hangs, **When** executed by the effector, **Then** the system enforces a strict timebox timeout, aborting execution and returning a timeout error.

---

### Edge Cases

- **Duplicate Connector Names**: What happens if two modules in the connectors directory define the same connector name? The system should validate names at startup, log a warning/error, or predictably prioritize one.
- **Empty or Whitespace Credentials**: How does the system handle a resolved credential value that is empty or contains only whitespace? It must be treated as missing and fail closed.
- **State Store Side Effects**: Connectors may call state persistence. The containment must ensure that database/store actions do not hang indefinitely or bypass safety checks.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST dynamically auto-discover all modules implementing the connector behaviour in the connectors directory at boot time.
- **FR-002**: System MUST build the connector registry map solely from the auto-discovered modules' metadata.
- **FR-003**: System MUST NOT require editing any central lists, gate logic, or effector dispatch logic to register or use a new connector.
- **FR-004**: System MUST project a specification capability into a manifest grant by querying the connector's own scope mapping function.
- **FR-005**: System MUST render capability consent lines deterministically by calling the connector module's rendering function.
- **FR-006**: System MUST resolve connector credentials dynamically using the declared ID in the connector's metadata, mapping it to uppercase environment variables or configuration blocks.
- **FR-007**: System MUST execute connector actions within a timebox and rescue wrapper to contain crashes and infinite hangs.

### Key Entities

- **Connector Module**: A self-contained code module implementing the connector behaviour, encapsulating metadata, scope projection, execution logic, and consent rendering.
- **Connector Registry**: A dynamic, in-memory index built at startup listing all auto-discovered capability modules and their metadata.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Adding a new capability requires modifying exactly one file (the new capability module).
- **SC-002**: All 4 existing capabilities (kv_append, external_send, gmail_read, gmail_draft) run successfully on the pluggable path.
- **SC-003**: The entire existing test suite (including the world-B verification battery) runs unchanged and remains green.
- **SC-004**: Connector execution errors or infinite hangs are isolated within a defined timebox (e.g. 5 seconds) without crashing the runtime process.

## Assumptions

- Discovered capability modules are trusted substrate code but execute fallible external I/O.
- The format of the metadata map returned by the registry to the gate remains unchanged to avoid modifying gate evaluation logic.
- Low-level credential loading (reading .env files) is handled by the existing credential proxy/source.
