# Contract: Agent Lifecycle Seam

The UI contract for lifecycle controls. The web layer (`InventoryLive`) calls **only**
`AgentOS.AgentLifecycle`; that module calls the registry, `TriggerArming`, the filesystem, and
StateStores. Deployment-record writes remain exclusively inside `DeploymentRegistry`
(Constitution IX single-writer).

## `AgentOS.AgentLifecycle` (new)

All functions are substrate-side, synchronous, and return `:ok | {:error, reason}`.

```elixir
@spec pause(String.t()) :: :ok | {:error, :not_deployed}
```
Marks the agent inactive (`DeploymentRegistry.mark_inactive/1`). Every trigger path then refuses to
fire it. Errors if the agent has no deployment record. Idempotent on an already-paused agent.

```elixir
@spec resume(String.t()) :: :ok | {:error, :not_deployed | :manifest_missing}
```
`DeploymentRegistry.mark_active/1` (preserving `deployed_at`/`provenance`) then
`TriggerArming.rearm/1`. Does NOT fire the startup trigger (resume is not a redeploy). Errors if
there is no record, or if the manifest file backing the record is gone.

```elixir
@spec delete(String.t()) :: :ok
```
Permanent removal, in order: (1) `DeploymentRegistry.delete/1`; (2) `TriggerArming.disarm/1`;
(3) `File.rm_rf("agents/<name>")` + `File.rm("manifests/<name>.md")`; (4) `{:delete_in, [name]}` on
`spend_ledger`, `provenance`, `conformance`, `judge_results`, `security_review_results`; (5) sweep
matching `pending_approvals`. `data/run_log.md` is left intact. Idempotent and tolerant of partial
state (missing files/keys are logged and skipped, never raised). Always returns `:ok`.

```elixir
@spec update_spend_cap(String.t(), number()) :: :ok | {:error, :invalid_cap | term()}
```
Validates `dollars > 0`; `Manifest.load` → set `spend.cap = round(dollars * 1_000_000)` →
`Projection.write/2`. Rejects zero/negative/non-numeric with `{:error, :invalid_cap}` and no write.
Accumulated `spend_ledger` state is untouched.

```elixir
@spec update_triggers(String.t(), [map()], keyword()) :: :ok | {:error, term()}
```
Replaces the agent's FULL trigger list (add/remove/retype in one edit). Entries may be atom- or
string-keyed (manifest shape or raw form params). Allowed types exactly: `startup`, `time`
(requires valid `at` "HH:MM", 00:00–23:59), `event` (requires non-empty `name`), `message` (no
params). Atomic validation: any invalid entry (`{:invalid_time, at}`, `:invalid_event_name`,
`{:unknown_trigger_type, t}`) or duplicate (`:duplicate_triggers`) rejects the whole edit with no
write. An empty list succeeds (agent becomes inert). On success: `Projection.write/2` then
`TriggerArming.rearm/1` — removed/retyped times stop firing, new times arm immediately. A startup
trigger added/kept by an edit does NOT fire on the edit (startup fires only at deploy completion
and boot).

## `AgentOS.DeploymentRegistry` (additions)

```elixir
@spec mark_active(String.t()) :: :ok
```
Mirror of `mark_inactive/1`: flips `active: true`, preserving `deployed_at`/`provenance`. Warns and
no-ops for an unknown agent. NOT `record_deployment/3` (which would reset `deployed_at` and require a
provenance).

```elixir
@spec delete(String.t()) :: :ok
```
`StateStore.apply_action("deployments", {:delete_in, [agent_name]})`. Warns and no-ops for an
unknown agent. Keeps the registry the sole writer to `"deployments"`.

Moduledoc "production write sites" list is updated to include the lifecycle seam.

## `AgentOS.TriggerArming` (additions / changes)

- State change: `armed :: %{agent_name => %{at => timer_ref}}` (was `%{agent_name => [at]}`).

```elixir
@spec disarm(String.t()) :: :ok    # GenServer.call
```
Cancels every armed timer for the agent (`Process.cancel_timer/1`) and drops it from `armed`.

```elixir
@spec rearm(String.t()) :: :ok     # GenServer.call
```
Disarms, then reloads the manifest via `DeploymentRegistry.get/1` → `manifest_path` and arms the
current `:time` triggers — only if the record exists and is active.

- `handle_info({:fire, agent, at}, …)`: re-arms the next occurrence **only if `armed[agent][at]`
  still exists** (stale-fire guard). Fire execution stays registry-gated as today.

## Invariants preserved

- Registry is the sole writer to `"deployments"`.
- Manifest never crosses the port boundary (edits are substrate-side, `manifests/` only).
- Lifecycle confers no capability; it gates dispatch and edits declared config only.
- All failures log with context and return typed errors (no silent swallow).
