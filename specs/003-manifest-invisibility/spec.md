# Feature Specification: Manifest Invisible to the Agent

**Feature Branch**: `003-manifest-invisibility`
**Created**: 2026-06-28
**Status**: Draft
**Input**: User description: "The enforcement manifest must be invisible to the agent. The manifest defines the agent's envelope — its grants (connector, recipients, methods), spend caps, and approval requirements — and is used only by the substrate's gate to evaluate the agent's proposed actions. None of that envelope information may ever cross the port boundary into the agent's container."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Envelope absent from every agent-reachable surface (Priority: P1)

As the operator of the substrate, I need an automated guarantee that the agent — including a compromised or hostile one — cannot read its own enforcement envelope. The agent receives only the data it needs to do its work (`{state, items}`) and the schema describing how to propose actions. The grants, recipients, methods, spend caps, approval requirements, and any credentials live only in the substrate and are used solely by the gate.

**Why this priority**: This is the core invariant of the feature and the whole point of separating the gate from the agent. If the envelope leaks, an adversarial agent can tailor its output to slip past the gate or learn what credentials exist. It is the only story; everything else supports it.

**Independent Test**: Run a single agent run and inspect every surface the agent can reach — the payload serialized across the port, the container mount set, and the container environment — and confirm none of them contain any envelope key, envelope value, or credential. Fully verifiable by an automated contract test without a live agent.

**Acceptance Scenarios**:

1. **Given** a configured manifest with grants, recipients, methods, and spend caps, **When** the substrate prepares the payload sent to the agent for a run, **Then** the serialized payload contains only the run state and items (plus the action schema) and none of the envelope keys or values.
2. **Given** a run is launched in the container sandbox, **When** the container mount set is constructed, **Then** the manifest file path is not mounted into the container.
3. **Given** a connector that requires a mutating credential, **When** the container environment is constructed, **Then** no mutating credential value is present in the agent's environment.
4. **Given** a future change that accidentally adds envelope data to the payload, mounts, or environment, **When** the test suite runs, **Then** the boundary-invariant test fails loudly and blocks the regression.

### Edge Cases

- What happens when a connector or grant uses a name that also appears legitimately in run data (e.g. an item title coincidentally containing the word "send")? The invariant is about envelope-derived content crossing the boundary, not arbitrary substrings; the test asserts the concrete envelope keys and the specific configured envelope values are absent, not that those words can never appear in user data.
- How does the system handle a manifest that declares no credentialed connectors? The environment check still passes (vacuously) and must not error.
- What happens if the payload is later extended with new legitimate fields? The top-level payload shape is asserted to be exactly the agreed set, so any new field is a deliberate decision that updates the contract and its test together.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The payload the substrate sends across the port to the agent MUST consist only of the run state and the run items, plus the published action schema the agent emits against.
- **FR-002**: The agent-bound payload MUST NOT contain any manifest envelope key: `grants`, `recipients`, `methods`, `cost`, `requires_approval`, `spend.cap`, `spend.window`, or `spend.on_breach`.
- **FR-003**: The agent-bound payload MUST NOT contain any manifest envelope value (e.g. configured connector names used as grants, recipient identifiers, method names, or spend figures) nor any credential/secret.
- **FR-004**: The container mount set MUST NOT include the manifest file path, so the agent cannot read the manifest off disk.
- **FR-005**: The agent's environment MUST NOT contain any mutating credential.
- **FR-006**: The substrate MUST carry an automated boundary-invariant test that verifies FR-001 through FR-005 and fails loudly on any regression.
- **FR-007**: The modules responsible for constructing the run and for owning the manifest MUST carry an explicit, discoverable statement that the manifest is gate-only and never crosses the boundary.

### Key Entities *(include if feature involves data)*

- **Enforcement envelope**: The manifest-derived set of constraints the gate uses — grants (connector, recipients, methods), spend caps, approval requirements, and credential references. Substrate-only; never sent to the agent.
- **Agent-bound payload**: The data the substrate hands the agent for a run — run state records and sanitized items — plus the action schema. The only thing that legitimately crosses the boundary into the agent.
- **Container surface**: The set of things an agent process can observe — the payload it receives, the filesystem paths mounted into it, and its environment variables.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of the manifest's envelope keys and configured envelope values are absent from the serialized agent-bound payload, verified automatically.
- **SC-002**: The manifest file path appears in 0 entries of the container mount set.
- **SC-003**: 0 mutating credentials are present in the agent environment for any run.
- **SC-004**: Any future change that reintroduces envelope data onto an agent-reachable surface is caught by the test suite before merge (the invariant test fails).
- **SC-005**: A reader of the run-construction and manifest-owning modules can determine, from in-code documentation alone, that the manifest never crosses the boundary.

## Assumptions

- The current architecture already satisfies this invariant; this feature proves and protects it rather than changing runtime behavior.
- The agent-bound payload shape is `{state, items}` plus the action schema, consistent with the existing port-boundary contract.
- "Mutating credential" refers to any secret that authorizes an outbound or state-changing connector action; read-only run data is not a credential.
- The boundary-invariant test exercises the real payload-construction and sandbox-argv code paths rather than reconstructing them, so it stays honest as the implementation evolves.
- Network isolation and filesystem read-only enforcement from the existing sandbox feature remain in place and are out of scope here.
