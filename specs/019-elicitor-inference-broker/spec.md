# Feature Specification: Route Elicitor through Inference Broker

**Feature Branch**: `019-elicitor-inference-broker`  
**Created**: 2026-07-01  
**Status**: Draft  
**Input**: User description: "Route the Elicitor agent through the substrate's inference chokepoint instead of calling OpenRouter directly."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Centralized Inference Elicitation (Priority: P1)

The specification elicitation process must route its inference queries through the substrate's centralized inference chokepoint rather than connecting directly to OpenRouter.

**Why this priority**: Crucial for security, credential isolation, and ensuring the substrate is the sole holder of LLM API keys.

**Independent Test**: Can be verified by running a live elicitor session and checking that it uses the substrate's Unix domain socket connection, without exposing or requiring any direct API key.

**Acceptance Scenarios**:

1. **Given** the substrate is running and has the centralized inference broker active, **When** a live elicitor session is started and a user message is sent, **Then** the completion request is routed through the substrate's UDS proxy, and the user receives the structured elicitation question.
2. **Given** an active elicitation session, **When** the user inputs an out-of-scope requirement, **Then** the elicitor detects scope creep and pushes back with a minimized alternative.

---

### User Story 2 - Metering and Spend Cap Enforcement (Priority: P1)

Elicitation inference spend must be accounted for and limited to prevent runaway onboarding costs.

**Why this priority**: Protects against unexpected LLM API spend during user onboarding / spec definition.

**Independent Test**: Can be verified by running elicitor calls and checking the spend ledger, and by setting the cap to a low value and verifying that a breach blocks further calls.

**Acceptance Scenarios**:

1. **Given** an active elicitation session, **When** a completion is requested and returns successfully, **Then** the micro-dollar cost of that completion is recorded in the spend ledger under the "elicitor" identity.
2. **Given** the "elicitor" spent amount exceeds the configured elicitation spend cap, **When** another elicitation completion is requested, **Then** the request is blocked, the breach is logged, and the elicitation session returns an error.

---

### User Story 3 - Offline Mock Elicitation (Priority: P1)

The offline deterministic mock path must remain functional to support offline tests.

**Why this priority**: Ensures tests can run offline and deterministically without contacting live models or UDS sockets.

**Independent Test**: Can be verified by running the elicitor with `MOCK_ELICITOR=true` and checking that it completes offline.

**Acceptance Scenarios**:

1. **Given** `MOCK_ELICITOR=true` is set in the environment, **When** the elicitor is invoked, **Then** it returns the predefined deterministic responses without attempting to connect to the UDS socket or the internet.

---

### Edge Cases

- **Broker Offline or Socket Missing**: If the UDS socket is unavailable, the elicitor must fail gracefully with a descriptive error.
- **Malformed LLM Output**: If the model returns unstructured output that does not conform to the expected schema, the elicitor must fail closed and report a parsing error.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The elicitor agent MUST obtain LLM completions by connecting to the substrate's Unix domain socket ($INFERENCE_SOCKET) and executing the centralized inference protocol.
- **FR-002**: The elicitor agent MUST NOT read, require, or reference the `MODEL_KEY` environment variable.
- **FR-003**: The substrate MUST register a reserved system run-token and associate it with a dedicated "elicitor" agent identity and manifest.
- **FR-004**: All elicitor inference calls MUST be metered in micro-dollars and recorded in the spend ledger under the "elicitor" identity.
- **FR-005**: The substrate MUST enforce a configurable spend cap for elicitation; calls exceeding this cap MUST be blocked by the broker.
- **FR-006**: The elicitor's deterministic mock mode (`MOCK_ELICITOR=true`) MUST bypass all network and UDS calls, running entirely offline.

### Key Entities *(include if feature involves data)*

- **Elicitor identity**: A system-level agent identity mapped in the inference broker and spend ledger, holding the spend cap and accumulated spend.
- **Centralized Inference Broker**: The substrate service that holds the model credentials, routes UDS inference requests to the provider, and meters micro-dollars.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of live elicitation completions are metered in the spend ledger.
- **SC-002**: A breach of the elicitation spend cap blocks further calls within 1 call.
- **SC-003**: Elicitor mock mode performs zero network or socket connection attempts.

## Assumptions

- Elicitation uses the standard project configuration for the OpenRouter model string.
- The spend cap for elicitation is daily and resets automatically like other agents.
