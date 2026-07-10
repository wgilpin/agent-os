# Data Model: UI-Driven Pipeline & Durable Deployments

## DeploymentRecord (NEW — `AgentOS.DeploymentRecord`)

The registry entry making "deployed" durable. Single-writer
(`AgentOS.DeploymentRegistry`), stored in the `"deployments"` StateStore keyed by
`agent_name`, rehydrated at boot.

| Field | Type | Notes |
|-------|------|-------|
| `agent_name` | `String.t()` | Registry key. Derived from manifest filename (substrate stays agent-agnostic). |
| `manifest_path` | `String.t()` | Path to the deployed manifest, e.g. `manifests/<name>.md`. |
| `deployed_at` | `DateTime.t()` | UTC timestamp of the completing deploy. |
| `provenance` | `:reviewed_human \| :skipped_in_envelope \| :dangerously_skipped` | How the deploy completed. History remains in the `"provenance"` store. |
| `active` | `boolean()` | Gates dispatch. Set `false` by `mark_inactive/1` (e.g. missing manifest at boot). |

**Transitions**:
- (absent) → active: `record_deployment/3` on deploy completion (direct or
  approval-resumed).
- active → active: redeploy upserts (new `deployed_at`/`provenance`), never duplicates.
- active → inactive: `mark_inactive/1` (boot missing-manifest edge; future undeploy).
- inactive → active: redeploy.

**Invariants**: exactly one record per agent_name; only `DeploymentRegistry` writes the
store; a record is never created by a blocked or denied deploy.

## ProgressEvent (NEW — `AgentOS.Pipeline.ProgressEvent`)

Typed event published during a pipeline run; consumed live by the UI and derivable
from the persisted run record. Never persisted itself.

| Field | Type | Notes |
|-------|------|-------|
| `run_id` | `String.t()` | Keys the per-run topic `"pipeline:" <> run_id`. |
| `agent_name` | `String.t()` | For the firehose topic consumers (inventory). |
| `stage` | `:manifest \| :classify \| :agent \| :judge \| :security_review \| :deploy \| :pipeline` | `:pipeline` for terminal events. |
| `status` | `:started \| :finished \| :failed \| :deployed \| :blocked \| :stopped` | Terminal statuses only appear with `stage: :pipeline`. |
| `detail` | `term()` | Verdict atom, blocked approval ref, stop reason, or `nil`. |
| `at` | `DateTime.t()` | Emission time. |

**Transport**: `{:pipeline_progress, %ProgressEvent{}}` broadcast on `AgentOS.PubSub`
to both `"pipeline:" <> run_id` and `"pipeline:all"`.

**Event sequence per run**: for each executed stage, `:started` then `:finished` (or
`:failed`); verdict-bearing stages carry the verdict in `detail`; exactly one terminal
event (`:deployed`, `:blocked` with ref, or `:stopped` with reason).

## PipelineRun (EXISTING, extended — `AgentOS.Pipeline.Orchestrator.PipelineRun`)

Persisted per-run outcome in the `"pipeline_runs"` store (keyed by agent_name), read
by the UI for history and refresh-reconnection.

**New field**: `run_id :: String.t() | nil` — lets a reconnecting LiveView re-subscribe
to the live topic and discard stale events. All other fields unchanged (`stages`,
`judge_verdict`, `security_verdict`, `deploy_result`, `provenance`, `outcome`,
`stopped_at`, `reason`, timestamps) and are sufficient to reconstruct the progress
panel (FR-003).

## PendingApproval (EXISTING — unchanged)

Parked consent-gated deployment in the `"pending_approvals"` store
(`%{ref, action :: ProposedAction, grant :: Grant}` with `action.type == "deploy"`,
`action.recipient == agent_name`, `action.method == manifest_path`). This feature adds
no new approval mechanics; the approval-resume path additionally writes a
DeploymentRecord when the action is deploy-shaped.

## Relationships

```text
ElicitedSpec ──(Orchestrator.run/3)──▶ PipelineRun ──(persisted)──▶ "pipeline_runs"
     │                                     │
     │                                     └─(broadcast)──▶ ProgressEvent ▶ PubSub topics
     │
     └─▶ Provisioner.deploy ──┬─ direct success ─────────────▶ DeploymentRecord (active)
                              └─ blocked ▶ PendingApproval ─▶ approve ▶ DeploymentRecord
                                                            └─ deny ──▶ (no record)

DeploymentRecord(active) ──gates──▶ TriggerGateway dispatch (time/event/message)
                        ──boots──▶ TriggerArming (per-agent time triggers)
```
