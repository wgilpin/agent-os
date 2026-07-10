# Contract: Pipeline Progress Events (PubSub)

Typed live-progress channel from `AgentOS.Pipeline.Orchestrator` to the web UI.
Transport is the existing `AgentOS.PubSub` (Phoenix.PubSub); payloads are
`AgentOS.Pipeline.ProgressEvent` structs (FR-010) — never bare maps.

## Topics

| Topic | Audience | Content |
|-------|----------|---------|
| `"pipeline:" <> run_id` | ElicitationLive (the run's owner) | Every event for that run. |
| `"pipeline:all"` | InventoryLive (firehose) | Every event for every run. |

Every event is broadcast to BOTH topics.

## Message shape

```elixir
{:pipeline_progress, %AgentOS.Pipeline.ProgressEvent{
  run_id: "run_...",          # keys the per-run topic
  agent_name: "...",
  stage: :manifest | :classify | :agent | :judge | :security_review | :deploy | :pipeline,
  status: :started | :finished | :failed | :deployed | :blocked | :stopped,
  detail: term(),              # verdict atom | blocked ref | stop reason | nil
  at: %DateTime{}
}}
```

## Emission rules

1. Each executed stage emits `:started` before work and `:finished` (or `:failed`,
   with the reason in `detail`) after.
2. Verdict stages (`:judge`, `:security_review`) put the verdict status in `detail`
   of their `:finished`/`:failed` event.
3. Exactly one terminal event per run, with `stage: :pipeline`:
   - `status: :deployed`, `detail: provenance`
   - `status: :blocked`, `detail: approval_ref` (consent-gated park)
   - `status: :stopped`, `detail: reason` (any failure/short-circuit)
4. Events are observability, not control flow: broadcast failure is logged and never
   aborts the pipeline.
5. Refresh/reconnect does NOT replay events — the UI reconstructs the panel from the
   persisted `PipelineRun` record (`"pipeline_runs"` store, keyed by agent_name,
   carrying `run_id`) and resumes live via re-subscription (FR-003).

## Consumers

- **ElicitationLive**: subscribes to the per-run topic when it starts a run; renders
  the stage-progress panel; on terminal event shows deployed / blocked (link to
  `/consent`) / stopped+reason.
- **InventoryLive**: subscribes to `"pipeline:all"` on connected mount; any event
  triggers a data refresh (registry + stores). The existing 5s poll remains as
  fallback.
