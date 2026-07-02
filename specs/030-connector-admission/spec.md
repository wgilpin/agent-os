# Feature Specification: Connector Admission + Compile-Isolated Plugins

**Feature Branch**: `030-connector-admission`  
**Created**: 2026-07-02  
**Status**: Draft  
**Input**: User description: "Establish the trust and loading boundary for third-party connectors: contract isolation, compile isolation, dynamic loading, and an admission gate."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Contract Isolation (Priority: P1)

As a system operator, I want connectors to be isolated from direct substrate state access (e.g. calling `StateStore` directly) by returning a described effect that the effector applies, ensuring that connectors do not have ambient authority to mutate the substrate state.

**Why this priority**: Crucial safety and trust-boundary requirement. By moving the mutation authority to the effector, we prevent connector code from directly altering the database or state stores, enforcing the "No Ambient Authority" principle.

**Independent Test**: Migrate the `kv_append` connector to return a described effect tuple (such as `{:state_store, :append, "roster_trust", {:append, :records, payload}}`) instead of invoking `AgentOS.StateStore.apply_action/2` directly. Verify that the effector executes the returned effect, producing identical state mutations, and that all world-B tests remain green.

**Acceptance Scenarios**:

1. **Given** a connector executing an action, **When** it completes, **Then** it returns a structured representation of the effect rather than modifying any substrate state itself.
2. **Given** a returned effect from a connector, **When** the effector receives it, **Then** the effector performs the check and applies the mutation at the chokepoint.

---

### User Story 2 - Compile Isolation (Priority: P2)

As a package author / substrate maintainer, I want third-party connectors to reside in a separate compilation unit (e.g., a separate Mix app or package) so that a connector that fails to compile or has bad dependencies does not break the core substrate build.

**Why this priority**: Ensures build stability. Developers must be able to compile and boot the core substrate even if a newly added third-party connector has syntax errors or unresolved dependencies.

**Independent Test**: Introduce a third-party connector in a separate mix app (e.g. under `plugins/` or a separate folder) and inject a syntax error. Verify that the core mix app still compiles and passes its test battery.

**Acceptance Scenarios**:

1. **Given** a third-party plugin package with compilation errors, **When** compiling the core substrate Mix project, **Then** the core compiles successfully.
2. **Given** a separate plugin compilation unit, **When** it compiles successfully, **Then** its resulting `.beam` files can be discovered by the loader.

---

### User Story 3 - Dynamic Loading and Discovery (Priority: P3)

As a system user, I want to be able to install and load third-party connector plugins dynamically without having to rebuild the core substrate code.

**Why this priority**: Enables plugin extensibility at runtime, allowing new connectors to be registered without service interruption or code compilation cycles on the core.

**Independent Test**: Drop a precompiled connector module `.beam` file into a designated plugins directory. Verify the auto-discovery registry detects and loads it without a core reboot or recompile.

**Acceptance Scenarios**:

1. **Given** a new precompiled connector module placed in the plugins path, **When** the registry scans, **Then** the module is loaded and discoverable.
2. **Given** a dynamically loaded connector, **When** it is uninstalled (file removed), **Then** the registry reflects its removal without reboot.

---

### User Story 4 - Human Admission Gate & Credential Provisioning (Priority: P4)

As a system administrator, I want to explicitly review and admit third-party connectors before they can be discovered or executed, provisioning their declared credentials during the admission process.

**Why this priority**: Ensures that third-party code running in-process is approved and safely wired to its secrets. Un-admitted code is blocked from executing or being advertised to agents.

**Independent Test**: Attempt to use an un-admitted connector. Verify it is not discoverable. Admit it via a reviewed registration action (e.g., adding it to an admitted plugins roster with mapped secrets), and verify it is now discoverable and runs with correct credential injection.

**Acceptance Scenarios**:

1. **Given** a newly loaded connector file, **When** it has not been admitted, **Then** the registry refuses to list it or make it discoverable.
2. **Given** an explicit admission command that matches the module hash and maps its credentials, **When** execution is attempted, **Then** the connector runs successfully.

---

## Edge Cases

- **Malicious Effects**: If a connector attempts to return an effect that modifies namespaces or stores it doesn't have access to, the effector/gate must reject it.
- **Corrupt plugin files**: If a `.beam` file is corrupt, the dynamic loader must catch the VM load error and fail closed, logging a loud error without crashing the VM.
- **Duplicate connector names**: If two plugins declare the same connector name, the registry must reject the second one and log a collision warning.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Connectors MUST NOT directly modify substrate state; they MUST return a descriptive data structure (the effect contract) representing the proposed change.
- **FR-002**: The substrate Effector MUST interpret and apply the descriptive effect returned by a connector at the chokepoint.
- **FR-003**: Third-party connectors MUST live in a separate compilation unit (separate Mix project or workspace) so compile errors do not affect core compilation.
- **FR-004**: The system MUST support dynamic loading of connector modules (e.g., from a designated plugins folder) at runtime.
- **FR-005**: An un-admitted connector module MUST NOT be loaded or discoverable in the registry.
- **FR-006**: Admitting a connector MUST be an explicit, reviewed action that records the connector's presence (hash/identity) and configures its declared credential mappings.
- **FR-007**: The system MUST map the connector's declared credential ID to its credential source (e.g., environment variable) at admission time.
- **FR-008**: First-party connectors (`kv_append`, `external_send`, `gmail_read`, `gmail_draft`) MUST continue to run on the pluggable path, maintaining backwards-compatibility and green world-B verification suites.

### Key Entities *(include if feature involves data)*

- **Described Effect**: A structured map/tuple returned by `execute/2` representing a state mutation.
- **Admission Log / Roster**: The persistent list of approved connector hashes, module names, and credential bindings.
- **Plugin Loader**: The component responsible for reading and loading `.beam` files from the plugins directory.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of connector state mutations are applied by the substrate effector, with zero direct state store calls from the connector's `execute/2`.
- **SC-002**: A syntax/compilation error in a third-party plugin mix app does not prevent the core substrate from compiling successfully.
- **SC-003**: Placing an admitted connector BEAM file in the plugins folder makes it discoverable in under 1 second without restarting or rebuilding the core.
- **SC-004**: An un-admitted connector is ignored by the registry loader and cannot be executed by the effector.

## Assumptions

- We assume the VM has write access to a designated directory where plugin `.beam` files can be placed.
- We assume that first-party connectors can be pre-admitted by default.
- We assume that the admission gate data is stored inside a secure namespace in the `StateStore` (or standard storage).
