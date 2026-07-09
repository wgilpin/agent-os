# Phase 1 Data Model: Agent Lifecycle Controls

No new persistent entities are introduced. This feature adds write paths over existing typed state.

## Entities (existing, reused)

### DeploymentRecord (`lib/agent_os/deployment_record.ex`)
Typed registry entry in the `"deployments"` StateStore, one per agent, keyed by `agent_name`.

| Field | Type | Lifecycle-controls interaction |
|-------|------|-------------------------------|
| `agent_name` | `String.t()` | key; unchanged by pause/resume; removed by delete |
| `manifest_path` | `String.t()` | read by `rearm/1`; preserved by pause/resume |
| `deployed_at` | `DateTime.t()` | **preserved** by pause/resume (SC-002); gone on delete |
| `provenance` | `:reviewed_human \| :skipped_in_envelope \| :dangerously_skipped` | **preserved** by pause/resume; gone on delete |
| `active` | `boolean()` | pause → `false`; resume → `true`; delete → record removed |

**State transitions**:
```
never-deployed (nil)
      │ record_deployment/3 (existing deploy path — not this feature)
      ▼
   active: true ──pause (mark_inactive)──▶ active: false
        ▲                                      │
        └──────── resume (mark_active) ────────┘
   (either state) ──delete──▶ never-deployed (record removed)
```
`mark_active/1` and `delete/1` are the two new registry writers; the registry remains the sole
writer to `"deployments"` (Constitution IX).

### Manifest (`lib/agent_os/manifest.ex`)
The agent's authority document on disk at `manifests/<name>.md`. Edited by two operations:

| Field | Type | Edit |
|-------|------|------|
| `spend.cap` | `non_neg_integer()` (micro-dollars) | `update_spend_cap` sets `round(dollars * 1_000_000)`, must be `> 0` |
| `triggers` | `[trigger()]` | `update_triggers` replaces the full list — add/remove/retype among `startup`/`time`/`event`/`message`; atomic validation; empty list allowed |

Round-trip: `Manifest.load/1` → mutate → `Manifest.Projection.write/2`. Writes are refused for paths
containing `agents/` (`projection.ex:171`), so edits stay under `manifests/`.

### Armed timer (in-memory, `lib/agent_os/trigger_arming.ex`)
The in-memory scheduled next occurrence of each daily `:time` trigger.

- **Before**: `armed :: %{agent_name => [at]}` (no refs).
- **After**: `armed :: %{agent_name => %{at => timer_ref}}` where `timer_ref` is the
  `Process.send_after/3` reference. Enables per-agent, per-time cancellation.

**Operations**:
- `disarm(agent_name)` — `Process.cancel_timer` every ref for the agent; drop the agent key.
- `rearm(agent_name)` — disarm, reload manifest via `DeploymentRegistry.get/1`, arm current `:time`
  triggers iff the record exists and is `active`.
- `handle_info({:fire, agent, at}, …)` — re-arm next occurrence **only if `armed[agent][at]` still
  present** (stale-fire guard).

### Per-agent runtime state (existing StateStores)
All keyed by `agent_name`, all removed on delete via `{:delete_in, [agent_name]}`:
`spend_ledger`, `provenance`, `conformance`, `judge_results`, `security_review_results`.

`pending_approvals` is keyed by `[:approvals, ref]`; delete sweeps entries whose action references
the agent (recipient == name, or a deploy action whose method basename == name, or a granted
connector type) using the filter from `inventory.ex:63-71`, removing each via
`{:delete_in, [:approvals, ref]}`.

`data/run_log.md` (global append-only history) is **not** modified.

## Validation rules

| Input | Rule | On violation |
|-------|------|--------------|
| spend cap (dollars) | numeric AND `> 0` | `{:error, :invalid_cap}`, no write |
| time trigger `at` | `HH:MM`, hour `0..23`, minute `0..59` | `{:error, {:invalid_time, at}}`, no write |
| event trigger `name` | non-empty string (trimmed) | `{:error, :invalid_event_name}`, no write |
| trigger type | exactly `startup`/`time`/`event`/`message` | `{:error, {:unknown_trigger_type, t}}`, no write |
| trigger list | no duplicate entries after normalization; empty allowed | `{:error, :duplicate_triggers}`, no write |
| pause target | must have a deployment record | `{:error, :not_deployed}` (graceful) |
| resume target | record present AND manifest file present | `{:error, :not_deployed}` / `{:error, :manifest_missing}` |
| delete target | any (idempotent) | never errors on absent/partial state; no-op is success |

All lifecycle functions return `:ok | {:error, reason}` for flash rendering (FR-012).
