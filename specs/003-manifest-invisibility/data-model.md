# Phase 1 Data Model: Manifest Invisible to the Agent

No new persisted entities and no schema changes. This feature reasons about three conceptual
entities that already exist; the "model" here is the boundary between them and the rules that
keep them separate.

## Entities

### Enforcement envelope (substrate-only)

The manifest-derived constraints the gate uses to evaluate proposed actions. Already modeled by
`AgentOS.Manifest` and its `Grant`/`Spend` structs plus the connector registry.

| Field | Source | Crosses to agent? |
|-------|--------|-------------------|
| `grants` (connector, recipients, methods) | `Manifest.grants` | **Never** |
| `spend` (cap, window, on_breach) | `Manifest.spend` | **Never** |
| `requires_approval?`, `cost`, `credential` | connector registry | **Never** |
| credential value (e.g. `outbound_token`) | `CredentialProxy` / env | **Never** |

### Agent-bound payload (the only thing that crosses)

What the substrate hands the agent for a run, serialized across the port.

| Field | Content | Source |
|-------|---------|--------|
| `state.records` | roster state snapshot records | `StateStore.snapshot("roster_trust")` |
| `items` | sanitized bookmark items | `Provisioner.load_and_sanitize_bookmarks/1` |
| (action schema) | the shape the agent emits against: `type`, optional `recipient`, optional `method`, `payload` | published contract, not data |

Top-level shape is exactly `{state, items}`. Any additional top-level key is a deliberate
contract change that must update `contracts/boundary.md` and the invariant test together.

### Container surface (everything the agent can observe)

| Surface | Producer | Invariant |
|---------|----------|-----------|
| Payload | `RunWorker` (JSON over the port) | contains only `{state, items}` + action schema |
| Mount set | `Sandbox.build_argv/1` | contains no host bind mount; never the manifest path |
| Environment | `Sandbox` env → `docker run -e` | contains no mutating credential |

## Validation Rules (map to functional requirements)

- **VR-001 (FR-001)**: The serialized agent-bound payload's top-level keys are exactly
  `["items", "state"]`.
- **VR-002 (FR-002)**: The serialized payload contains none of the envelope keys: `grants`,
  `recipients`, `methods`, `cost`, `requires_approval`, `spend`, `cap`, `window`, `on_breach`.
- **VR-003 (FR-003)**: The serialized payload contains none of the configured envelope values
  read from the loaded manifest (connector/grant names, recipients, methods, spend figures) nor
  any credential id.
- **VR-004 (FR-004)**: The argv from `Sandbox.build_argv/1` contains no bind-mount flag
  (`-v`/`--volume`) and no element referencing the manifest path / file.
- **VR-005 (FR-005)**: The argv from `Sandbox.build_argv/1` contains no mutating credential
  value.
- **VR-006 (anti-vacuousness)**: Before asserting absence, the test loads the real manifest and
  confirms it genuinely has non-empty grants and a spend cap, so VR-002/VR-003 are meaningful.
- **VR-007 (FR-007)**: `run_worker.ex` and `manifest.ex` each carry an `@moduledoc` statement
  that the manifest is gate-only and never crosses the boundary, naming the invariant test.

## State Transitions

None. This feature introduces no stateful entity and no lifecycle.
