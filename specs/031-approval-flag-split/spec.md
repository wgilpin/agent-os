# Feature Specification: Approval Flag Split

**Feature Branch**: `031-approval-flag-split`  
**Created**: 2026-07-02  
**Status**: Draft  
**Input**: User description: "Split the connector approval model into two independent flags: `requires_deploy_consent?` (build-time) and `requires_runtime_approval?` (per-call runtime)."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Separating Build-Time Consent and Runtime Approval (Priority: P1)

As a system operator, I want build-time deployment consent to be distinct from runtime per-call approval so that I can approve a notification or logging capability once at deploy time, and have it run freely without nagging at runtime.

**Why this priority**: Core value of the feature. Separating the flags allows safe, scoped, metered background operations (like notifications) to fire without nagging the user for every outbound call, while still ensuring the user consented to installing the egress path.

**Independent Test**: Configure a connector (such as a mock notification service) with `requires_deploy_consent?: true, requires_runtime_approval?: false`. Deploy an agent with this grant. Verify the deployment consent envelope is triggered and requires approval, but once deployed, the agent's proposed action executes immediately without parking.

**Acceptance Scenarios**:

1. **Given** an agent manifest requesting a connector with `requires_deploy_consent?: true`, **When** deploying, **Then** the system requires build-time human consent.
2. **Given** an agent running with a consent-granted connector that has `requires_runtime_approval?: false`, **When** the agent proposes a connector action, **Then** the gate authorizes the call directly without parking it for per-call sign-off.

---

### User Story 2 - Enforcing Runtime Per-Call Sign-Off (Priority: P2)

As a system owner, I want dangerous, high-blast-radius, or irreversible actions to continue to require manual runtime approval for each invocation.

**Why this priority**: Vital for security and preventing unauthorized external mutations (e.g. sending real emails to customer lists, withdrawing funds).

**Independent Test**: Configure a connector with `requires_runtime_approval?: true`. Run the agent. Verify the deterministic gate parks the proposed action, returning `{:needs_approval, grant}` and requiring human sign-off before executing.

**Acceptance Scenarios**:

1. **Given** an agent run, **When** a proposed action is checked by the gate for a connector with `requires_runtime_approval?: true`, **Then** the gate returns `{:needs_approval, grant}` and parks the action.
2. **Given** a parked action, **When** a human clicks approve, **Then** the effector executes the action.

---

### User Story 3 - Auto-Granting Safe Capabilities (Priority: P3)

As an agent runner, I want safe capabilities (e.g., reading/writing local state or drafting emails) to execute without build-time consent or runtime approval, maximizing developer velocity for safe tools.

**Why this priority**: Avoids unnecessary friction for risk-free operations.

**Independent Test**: Deploy an agent requesting `gmail_read` or `kv_append` (both configured with `requires_deploy_consent?: false, requires_runtime_approval?: false`). Verify the agent deploys and runs without triggering consent screens or parking actions.

**Acceptance Scenarios**:

1. **Given** an agent manifest with only `gmail_read` and `kv_append`, **When** deploying, **Then** the agent is auto-deployed without human consent screens.
2. **Given** the running agent, **When** it writes local keys, **Then** it executes instantly without interruption.

---

### User Story 4 - Legible Inventory badges (Priority: P4)

As a system administrator, I want both flags to be clearly visible and separately badged in the standing inventory and capability rendering screens.

**Why this priority**: Satisfies Principle VIII (Legibility is Non-Negotiable). Administrators must easily distinguish between build-time grants and runtime per-call throttles.

**Independent Test**: Query the capability rendering page or helper. Verify that the badges for `Deploy Consent` and `Runtime Approval` are displayed separately, dynamically matching each connector's metadata.

**Acceptance Scenarios**:

1. **Given** a capability render check, **When** reviewing `external_send`, **Then** both `requires_deploy_consent?` and `requires_runtime_approval?` badges are displayed.
2. **Given** a capability render check, **When** reviewing `kv_append` or `gmail_read`, **Then** no approval badges are shown.

---

## Edge Cases

- **Mismatched Flags**: A connector might have `requires_deploy_consent?: false, requires_runtime_approval?: true`. The system must handle this cleanly: no deploy consent needed, but per-call approval required at runtime.
- **Legacy code reference**: If any code references `requires_approval?`, compilation or static checks must fail.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The connector metadata schema MUST replace the single boolean `requires_approval?` with two orthogonal booleans: `requires_deploy_consent?` and `requires_runtime_approval?`.
- **FR-002**: The deterministic Gate MUST check `requires_runtime_approval?` to decide whether to park an action (`{:needs_approval, grant}`).
- **FR-003**: The Provisioner/Deployer MUST check `requires_deploy_consent?` on each requested grant at deploy time, and refuse deployment without consent.
- **FR-004**: The Capability Render module MUST present distinct labels/badges for `requires_deploy_consent?` and `requires_runtime_approval?`.
- **FR-005**: Safe local connectors (`kv_append`, `gmail_read`, `gmail_draft`, `web_search`) MUST default to `requires_deploy_consent?: false` and `requires_runtime_approval?: false`.
- **FR-006**: Dangerous external connectors (`external_send`) MUST default to `requires_deploy_consent?: true` and `requires_runtime_approval?: true`.
- **FR-007**: The system MUST perform a complete clean cutover: all code, tests, and specs MUST be purged of the legacy `requires_approval?` term.

### Key Entities *(include if feature involves data)*

- **Connector Metadata**: The struct/map representing the connector's configuration carrying the two approval flags.
- **Gate Result**: The outcome of gate evaluation (e.g. `:ok`, `{:needs_approval, grant}`, `{:error, reason}`).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of references to `requires_approval?` are deleted from the codebase.
- **SC-002**: An agent with a `requires_deploy_consent?` capability requires human consent during deploy.
- **SC-003**: An agent calling a `requires_runtime_approval?: false` connector executes it with zero runtime parking, even if `requires_deploy_consent?` was true.

## Assumptions

- We assume no active live deployment databases exist, allowing a hard cutover.
- We assume that the existing human consent screen and gate check logic can be easily updated to read the new properties.
