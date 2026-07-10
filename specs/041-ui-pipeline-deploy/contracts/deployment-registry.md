# Contract: Deployment Registry (`AgentOS.DeploymentRegistry`)

The sole writer to the `"deployments"` StateStore (Constitution IX). All functions are
typed; records are `AgentOS.DeploymentRecord` structs — no bare maps cross this
boundary (FR-010).

## API

### `record_deployment(agent_name, manifest_path, provenance) :: :ok`

- Upserts the record keyed by `agent_name`: `active: true`,
  `deployed_at: DateTime.utc_now()`, given `manifest_path` and `provenance`.
- Redeployment REPLACES the record (no duplicates); prior history lives in the
  `"provenance"` store.
- Callers (the ONLY two production call sites):
  1. `AgentOS.Provisioner.deploy/3` — non-blocking success branch (and idempotent
     upsert on the already-deployed short-circuit).
  2. `AgentOS.TriggerGateway` approval-resume `:approve` branch, only when the parked
     action has `type == "deploy"`.

### `get(agent_name) :: DeploymentRecord.t() | nil`

Read-only lookup.

### `list_active() :: [DeploymentRecord.t()]`

All records with `active: true`. Used by boot re-arming and InventoryLive.

### `deployed_and_active?(agent_name) :: boolean()`

Dispatch gate predicate. `false` for absent OR inactive records.

### `mark_inactive(agent_name) :: :ok`

Sets `active: false`, preserving the rest of the record. Used by boot re-arming when a
record's manifest file is missing (logged loudly first). No-op with a warning log if
the record is absent.

## Guarantees

- **Gating, not capability**: registry membership only decides whether a trigger
  dispatches; it confers no authority. The CapabilityRail remains the only firewall
  (Constitution X/XI).
- **Blocked/denied deploys never write**: a parked (`{:blocked, ref}`) or denied
  deployment leaves the registry untouched.
- **Durability**: the store is a term-file StateStore under `data/deployments.db`,
  configurable via `config :agent_os, :deployments_path` (tests use isolated paths).
- **Observability**: every refusal derived from this registry (unregistered/inactive
  agent trigger) is logged with agent name and trigger type (FR-006).
