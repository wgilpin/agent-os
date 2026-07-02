# Feature Specification: Synchronous Tools + Web Search

**Feature Branch**: `029-synchronous-tools`  
**Created**: 2026-07-02  
**Status**: Draft  
**Input**: User description: "Add a synchronous, mid-inference tool-use channel over the inference broker, and land `web_search` as the first tool connector."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Gated synchronous tool use (Priority: P1)

As an agent runner, I want my agent to be able to use synchronous tools (like web search) mid-reasoning so that it can retrieve current information and incorporate it immediately, provided it has the necessary grant in its manifest.

**Why this priority**: This is the core value of the feature. It enables the model to request a tool call mid-inference, pause execution, get the result, and continue reasoning in a single user-facing pass.

**Independent Test**: Configure an agent with a manifest granting the `web_search` capability. Run the agent with a query requiring real-time web search. Verify the system pauses inference, runs `web_search` synchronously, feeds results back into context, and yields the final response in one agent invocation.

**Acceptance Scenarios**:

1. **Given** an agent with a `web_search` grant, **When** the agent requests a completion requiring search, **Then** the system offers the tool, executes it synchronously upon model request, and returns the final answer with search content.
2. **Given** an agent run, **When** a synchronous tool is executed, **Then** the agent code itself is unaware of the tool loop orchestration, seeing only a single request-response cycle.

---

### User Story 2 - Access Control & Sandboxing (Priority: P2)

As a system operator, I want tool calls from agents without the corresponding grant to be blocked and never advertised to the model, preventing unauthorized operations.

**Why this priority**: Crucial security constraint that enforces the "No Ambient Authority" principle. It prevents agents from accessing tools unless explicitly granted.

**Independent Test**: Configure an agent without the `web_search` grant. Run the agent and attempt to invoke `web_search` (either implicitly by prompt or explicitly by injecting a tool-use action). Verify the tool is not in the model's schema and any manual call fails gate validation.

**Acceptance Scenarios**:

1. **Given** an agent without `web_search` grant, **When** the agent starts inference, **Then** the system does not include the search tool schema in the model payload.
2. **Given** an agent without `web_search` grant, **When** the agent forces a tool call action to the broker, **Then** the deterministic gate intercepts and blocks the call, returning an authorization error.

---

### User Story 3 - Metering and Spend Control (Priority: P3)

As a system owner, I want tool executions to be metered against the agent's spend cap so that runaway agents or expensive queries do not exceed budget constraints.

**Why this priority**: Ensures cost safety. Tool executions must contribute to the per-agent spend limit, and breaches must trigger standard kill-on-breach protocols.

**Independent Test**: Set a tight spend cap on an agent run. Execute the agent and trigger a tool call. Verify the tool query cost is added to the run's spend, and if the cap is exceeded, the run is terminated.

**Acceptance Scenarios**:

1. **Given** an agent run with a $0.05 spend limit, **When** a tool call costing $0.01 is executed, **Then** the system records the $0.01 cost and subtracts it from the remaining budget.
2. **Given** an agent run with a $0.01 spend limit, **When** a tool call costing $0.02 is requested, **Then** the system blocks execution, billing the run up to the breach point and terminating the process.

---

### User Story 4 - Fault Containment & Timeouts (Priority: P4)

As a system operator, I want tool failures, hangs, or crashes to be caught, timeboxed, and returned as a standard tool error to the model without crashing the running worker or the system broker.

**Why this priority**: Ensures system stability against buggy, slow, or rate-limited third-party APIs.

**Independent Test**: Run a mock tool connector designed to crash or hang. Verify the system terminates the call at the timeout threshold (or catches the crash), logs the error loudly, and passes a tool error back to the model so the run can continue or fail gracefully.

**Acceptance Scenarios**:

1. **Given** a tool that throws an unhandled exception, **When** the tool is invoked, **Then** the system catches the error, logs it, and feeds a tool error response to the model.
2. **Given** a tool that hangs indefinitely, **When** the tool is invoked, **Then** the system halts execution after a timeout, logs the timeout, and feeds a tool timeout error to the model.

---

## Edge Cases

- **Rate Limits**: If the search provider rate-limits the query, the system should catch the rate-limit response and feed a retryable error back to the model context.
- **Empty/Empty-ish Results**: When a search returns no matches, the system must feed a clean empty result back to the model without crashing.
- **Unicode/Encoding Issues**: The search results might contain malformed characters or non-standard encodings; the tool must normalize these before injecting them into model context.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST support a synchronous, mid-reasoning tool-use channel over the inference broker.
- **FR-002**: The system MUST dynamically build tool schemas from auto-discovered connector metadata.
- **FR-003**: The system MUST advertise tools to the model ONLY when the agent's manifest explicitly grants that capability.
- **FR-004**: The deterministic gate MUST validate and authorize every tool call prior to execution.
- **FR-005**: Every tool invocation MUST record its per-query cost and meter it against the agent run's spend cap.
- **FR-006**: The system MUST terminate the agent run immediately if a tool call breaches the spend cap.
- **FR-007**: The system MUST isolate tool executions with a timeout (defaulting to a safe maximum) and crash-recovery wrapper.
- **FR-008**: The system MUST format tool errors and inject them back into the model context, allowing the model to handle them.
- **FR-009**: The `web_search` tool MUST be implemented as a metered, credential-bearing connector implementing the tool interface.
- **FR-010**: Pluggable connectors MUST be auto-discoverable via the behaviour under `lib/agent_os/connector/` without editing a central registry list.

### Key Entities *(include if feature involves data)*

- **Tool Connector**: A module implementing the `AgentOS.Connector` behaviour that declares tool metadata, schema, credentials, cost, and a synchronous execution callback.
- **Manifest Grant**: The declarative mapping of a capability (such as `web_search`) and its scopes to an agent.
- **Inference Context**: The rolling list of messages (user, assistant, tool calls, tool results) passed between the inference broker and the model.
- **Spend Registry/Meter**: The run-time accumulator that tracks the cost of tokens and tool calls.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An authorized agent can complete a synchronous search and incorporate results in under 5 seconds (excluding model network time).
- **SC-002**: 100% of tool executions are metered; no tool calls can bypass the spend check.
- **SC-003**: 100% of ungranted tool execution attempts are blocked by the gate.
- **SC-004**: A tool exception or hang (exceeding timeout) must be caught and recovered within 100ms of the error/timeout occurrence without crashing the parent process.

## Assumptions

- We assume that the underlying LLM (e.g. Gemini 3 series) supports function calling / tool use.
- We assume that a search API credential is provided via environment variable (e.g., `SEARCH_API_KEY`) when search is run in a live environment.
- In test environments, the search API must be mocked/stubbed to avoid live network requests, satisfying Principle IV.
