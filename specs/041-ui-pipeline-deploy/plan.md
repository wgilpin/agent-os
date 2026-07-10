# Implementation Plan: UI-Driven Pipeline & Durable Deployments

**Branch**: `041-ui-pipeline-deploy` | **Date**: 2026-07-08 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/041-ui-pipeline-deploy/spec.md`

## Summary

Wire the web UI to the full generation pipeline (elicit → generate → judge → deploy →
execute-on-trigger) and make "deployed" a durable, restart-surviving runtime state.

Two halves:

1. **UI wiring**: on a confirmed elicited spec, ElicitationLive offers a per-run
   review-mode choice (default `:always_review`) and starts
   `AgentOS.Pipeline.Orchestrator.run/3` in a supervised async task. The orchestrator
   broadcasts typed `ProgressEvent` structs on the (currently dormant) `AgentOS.PubSub`;
   the LiveView renders a stage-progress panel and terminal outcome (deployed /
   blocked-pending-consent / stopped+reason). Progress is also reconstructable from the
   persisted `"pipeline_runs"` record, so a browser refresh rejoins a running or
   finished run.

2. **Durable deployment registry**: a new `"deployments"` StateStore holds typed
   `AgentOS.DeploymentRecord`s written by the deploy completion path only — both the
   direct-deploy success branch in `AgentOS.Provisioner.deploy/3` and the
   approval-resume branch in `AgentOS.TriggerGateway` (deploy-shaped actions). The
   registry gates dispatch for ALL trigger types (time, event, message): unregistered
   or inactive agents never fire, and the refusal is logged. At boot the substrate
   reads the registry and arms each active agent's declared triggers from its manifest,
   including per-agent time triggers (today ignored in favor of one global config
   hour). The legacy config-driven discovery schedule keeps working unchanged. A
   registry record whose manifest file is missing at boot is logged loudly and marked
   inactive — never a crash, never silent. Missed windows are not fired retroactively.

InventoryLive shows deployment state from the registry (not manifest-file existence),
subscribes to PubSub for live updates (5s poll kept as fallback), and offers a
message-trigger test-fire for deployed agents that declare one, routed through the
normal `TriggerGateway` dispatch path. ConsentLive gains no new mechanics.

## Technical Context

**Language/Version**: Elixir ~> 1.20 / OTP (BEAM), single local node
**Primary Dependencies**: Phoenix LiveView, Phoenix.PubSub (already started in the
supervision tree as `AgentOS.PubSub`, currently unused), OTP (GenServer,
Task.Supervisor). No new dependencies.
**Storage**: Existing term-file StateStore (single-writer GenServer, SQLite-style term
files under `data/`); new `"deployments"` collection at `data/deployments.db`. No
external database (Constitution IX).
**Testing**: ExUnit. Seeded StateStores, `provider_fn`/`start_run_fn`/`effector_fn`/
`manifests_fn` stub seams. NO live model calls, NO remote APIs, NO LiveView unit tests
(Constitution III/IV).
**Target Platform**: Local BEAM node (macOS dev), Phoenix web UI at localhost.
**Project Type**: Web-service (Phoenix LiveView UI over an Elixir/OTP substrate).
**Performance Goals**: N/A — single-user prototype; progress updates within one PubSub
delivery; inventory fallback poll every 5s as today.
**Constraints**: The LiveView must never block while the pipeline runs; trigger
dispatch must consult the registry on every fire; boot re-arming must not crash on a
missing manifest; no catch-up of missed time windows.
**Scale/Scope**: Single user, handful of agents, one browser session; concurrent
pipeline runs permitted but not optimized (events keyed per run).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Simplicity First | PASS | No new deps; reuses existing StateStore, PubSub, TriggerGateway seams. Registry is one struct + one thin single-writer module. |
| II. Explicit Scope Control | PASS | Scope = spec FR-001..FR-012; no undeclared extras. Undeploy UI explicitly out of scope. |
| III. Test-Driven Backend | PASS | Registry, dispatch gating, boot re-arming, event emission, test-fire routing all written test-first. LiveViews get NO unit tests — manual walkthrough (quickstart.md). |
| IV. No Live Dependencies in Tests | PASS | Pipeline stages stubbed via existing `provider_fn` opts; dispatch via `start_run_fn`/`manifests_fn` stubs; seeded stores. Hermeticity guards (`load_dotenv: false`, discord transport stub in test_helper) untouched. |
| V. Strong Typing, No Bare Maps | PASS | New `AgentOS.DeploymentRecord` and `AgentOS.Pipeline.ProgressEvent` structs with typespecs cross every new boundary (FR-010). |
| VI. Loud Failures | PASS | Dispatch refusals logged (FR-006); missing manifest at boot logged loudly + marked inactive; no swallowed errors. |
| VII. Self-Documenting | PASS | `@moduledoc`/`@doc` on every new module/function; intent comments on non-obvious blocks. |
| VIII. Legibility | PASS | Registry IS the standing "what is deployed" inventory; pipeline runs remain persisted and queryable. |
| IX. Substrate Owns State & Lifecycle | PASS | Single writer per store: `DeploymentRegistry` is the sole writer to `"deployments"`. Registry names come from manifests, no agent domain vocabulary enters `lib/agent_os/`. |
| X. No Ambient Authority | PASS | Registry membership confers no capability — it only gates whether a trigger dispatches. Manifest grants remain the entire power. |
| XI. Deterministic Gate Only Firewall | PASS | CapabilityRail unchanged and remains the only firewall. Registry is a dispatch precondition, not a gate replacement. |
| XII. Enforcement Precedes Generation | PASS | No ordering change; this feature wires existing v3 stages to the UI. |

**Post-Phase-1 re-check**: PASS — design introduces no violations; Complexity Tracking
is empty.

## Project Structure

### Documentation (this feature)

```text
specs/041-ui-pipeline-deploy/
├── plan.md              # This file
├── spec.md              # Feature specification (input)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output (manual browser walkthrough)
├── contracts/
│   ├── deployment-registry.md   # Registry semantics contract
│   └── pubsub-events.md         # ProgressEvent shape + topic contract
├── checklists/requirements.md   # Pre-existing quality checklist
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

```text
lib/agent_os/
├── deployment_record.ex          # NEW: typed registry record struct
├── deployment_registry.ex        # NEW: single-writer API over "deployments" store
├── trigger_arming.ex             # NEW: boot re-arming of per-agent triggers
├── application.ex                # EDIT: boot "deployments" store + TriggerArming
├── provisioner.ex                # EDIT: registry write on direct-deploy success
├── trigger_gateway.ex            # EDIT: registry-gated dispatch (all types);
│                                 #       registry write on deploy approval-resume
├── scheduler.ex                  # UNCHANGED: legacy global-hour discovery loop kept
└── pipeline/
    ├── progress_event.ex         # NEW: typed pipeline progress event struct
    └── orchestrator.ex           # EDIT: run_id threading + PubSub broadcasts

lib/agent_os_web/live/
├── elicitation_live.ex           # EDIT: review-mode select + start + progress panel
├── inventory_live.ex             # EDIT: registry-driven deploy state, PubSub
│                                 #       subscribe, message test-fire affordance
└── consent_live.ex               # UNCHANGED (verify flow in walkthrough)

test/agent_os/
├── deployment_registry_test.exs  # NEW: record writes, upsert, active flag
├── deployment_dispatch_test.exs  # NEW: registry-gated dispatch, all trigger types
├── trigger_arming_test.exs       # NEW: boot re-arming + missing-manifest edge
├── pipeline/orchestrator_progress_test.exs  # NEW: PubSub event emission
└── provisioner_deploy_registry_test.exs     # NEW: direct deploy + approval-resume
                                             #      write the registry
```

**Structure Decision**: Existing single-app Phoenix/OTP layout. All substrate changes
under `lib/agent_os/`, UI changes under `lib/agent_os_web/live/`, backend tests under
`test/agent_os/`. No new apps or packages.

## Design

### 1. Deployment registry (US3, FR-005/006/007)

- **`AgentOS.DeploymentRecord`** (`lib/agent_os/deployment_record.ex`): struct with
  `agent_name :: String.t()`, `manifest_path :: String.t()`,
  `deployed_at :: DateTime.t()`, `provenance :: atom()`, `active :: boolean()`.
- **`AgentOS.DeploymentRegistry`** (`lib/agent_os/deployment_registry.ex`): thin,
  sole-writer API over the `"deployments"` StateStore:
  - `record_deployment/3` (agent_name, manifest_path, provenance) — upsert keyed by
    agent_name (redeploy updates, never duplicates), sets `active: true`,
    `deployed_at: now`.
  - `get/1`, `list_active/0`, `deployed_and_active?/1`, `mark_inactive/1`.
  - All writes to `"deployments"` funnel through this module (Constitution IX).
- **Store boot**: `application.ex` gains an eleventh StateStore child:
  `name: "deployments"`, `path: Application.get_env(:agent_os, :deployments_path,
  "data/deployments.db")`, `initial: %{}`.
- **Write sites (deploy completion path ONLY)**:
  - `Provisioner.deploy/3` non-blocking success branch (`:review_if_risky` in-envelope
    or `:dangerously_skip_review`): after `record_provenance`, call
    `DeploymentRegistry.record_deployment/3`.
  - `TriggerGateway.dispatch_approval/3` `:approve` branch: when the parked action has
    `type == "deploy"`, after the effector runs, write the registry record
    (agent = `action.recipient`, manifest = `action.method`,
    provenance = `:reviewed_human`). Keyed off the action type so future non-deploy
    approvals never write deployment records. Substrate-side so the write is not
    UI-dependent.
  - The already-deployed short-circuit in `Provisioner.deploy/3` (same hash, deployed
    provenance) also ensures a registry record exists (idempotent upsert), healing
    pre-registry deployments.
- **Dispatch gating** (`trigger_gateway.ex`): `dispatch_event` and `dispatch_message`
  filter candidate agents through `deployed_and_active?/1` before firing. A
  `registry_fn` opt seam (default `&DeploymentRegistry.deployed_and_active?/1`) keeps
  tests hermetic. Refusals log at warning level with agent name and trigger type
  (FR-006). Time triggers are gated at arming time (below) AND at fire time.
- **Boot re-arming** (`AgentOS.TriggerArming`, new GenServer in the supervision tree
  after TriggerGateway): on init, read `DeploymentRegistry.list_active/0`; for each
  record load its manifest; for each `%{type: :time, at: "HH:MM"}` trigger arm a
  self-rescheduling daily timer (reusing `Scheduler.ms_until_next/2`-style math,
  generalized to minutes) that fires `RunSupervisor.start_run(trigger: "time:HH:MM",
  agent: name)` after re-checking the registry. Event/message triggers need no arming —
  they're pull-dispatched through the gateway, which now gates on the registry.
  A manifest that fails to load → `Logger.error` + `mark_inactive/1`, boot continues.
  No catch-up: arming always schedules the NEXT occurrence.
- **Legacy discovery schedule**: `Scheduler` (global config `run_hour` → discovery run)
  is left untouched. Rationale recorded in research.md (R4).

### 2. Pipeline progress events (US1, FR-003/010)

- **`AgentOS.Pipeline.ProgressEvent`** (`lib/agent_os/pipeline/progress_event.ex`):
  struct with `run_id :: String.t()`, `agent_name :: String.t()`,
  `stage :: :manifest | :classify | :agent | :judge | :security_review | :deploy | :pipeline`,
  `status :: :started | :finished | :failed | :deployed | :blocked | :stopped`,
  `detail :: term()` (verdict atom, blocked ref, or stop reason), `at :: DateTime.t()`.
- **Topics**: per-run `"pipeline:" <> run_id` and firehose `"pipeline:all"` (inventory).
  Broadcast helper `ProgressEvent.broadcast/1` publishes to both via
  `Phoenix.PubSub.broadcast(AgentOS.PubSub, topic, {:pipeline_progress, event})`.
  Broadcast failures are logged, never raised (progress is observability, not control
  flow).
- **Orchestrator changes**: `run/3` accepts/generates `run_id` (opt `:run_id`, default
  `"run_" <> unique`), stores it on `PipelineRun` (new field), and emits events at each
  stage boundary inside `safe_call/3` plus a terminal event (deployed/blocked/stopped).
- **Reconstruction**: the persisted `PipelineRun` (stages list, verdicts, outcome,
  `stopped_at`, `reason`, `run_id`) is sufficient to rebuild the progress panel after a
  refresh; `"pipeline_runs"` stays keyed by agent_name (single-user prototype; run_id
  recorded inside the struct — research R5).

### 3. ElicitationLive (US1, FR-001/002)

- On confirmed spec: keep writing the spec file, then instead of stopping, show a
  "Start pipeline" card: review-mode `<select>` with `:always_review` (default,
  labelled consent-gated), `:review_if_risky`, `:dangerously_skip_review` (never
  preselected, visually flagged dangerous) + Start button.
- Start: build the `AgentOS.ElicitedSpec` from the session draft (already typed),
  generate `run_id`, subscribe to `"pipeline:" <> run_id`,
  `Task.Supervisor.start_child(AgentOS.PipelineTaskSupervisor, fn ->
  Orchestrator.run(spec, mode, run_id: run_id) end)` — a new named Task.Supervisor in
  the app tree; the LiveView never blocks or links to the task.
- Progress panel renders accumulated `ProgressEvent`s; terminal states: deployed ✓,
  blocked-pending-consent (link to `/consent?manifest=<path>`), stopped + reason.
- Reconnect: on mount with an active run (run panel state lost), read
  `"pipeline_runs"` snapshot to rebuild; live events resume via re-subscribe.
- NO LiveView unit tests (Constitution III) — quickstart.md walkthrough covers it.

### 4. InventoryLive (US4, FR-008/009)

- Deployment badge per agent card driven by `DeploymentRegistry.get/1`:
  deployed-active / deployed-inactive / not-deployed.
- `connected?` mount subscribes to `"pipeline:all"`; `{:pipeline_progress, _}` triggers
  a data refresh. The 5s poll stays as fallback.
- Test-fire: for agents that are deployed+active AND declare `%{type: :message}`, a
  payload input + "Fire" button submits `TriggerGateway.submit_sync({:message, agent,
  payload})` — the normal dispatch path, so gating and run logging apply. Absent for
  everything else.

### 5. ConsentLive (US2)

No code change. The registry write for approval-resume lives in the substrate
(`TriggerGateway`), so approving in ConsentLive completes deployment AND registers the
agent with zero UI coupling. Verified in the manual walkthrough.

## Test Plan (TDD, backend only)

| Test file | Asserts |
|-----------|---------|
| `deployment_registry_test.exs` | Typed record on `record_deployment`; upsert on redeploy (no duplicates); `mark_inactive`; `list_active` filters inactive. Seeded isolated store. |
| `provisioner_deploy_registry_test.exs` | Direct deploy success (seeded pass verdicts, `:dangerously_skip_review` / in-envelope `:review_if_risky`) writes an active record; blocked `:always_review` deploy does NOT write; approval-resume (`{:approval, :approve, ref}` on a parked deploy) writes the record; deny does not. |
| `deployment_dispatch_test.exs` | Event/message/time dispatch refuses unregistered and inactive agents (assert no `start_run_fn` invocation + log); registered-active agents fire; refusal logged for a manifest on disk with no registry record. |
| `trigger_arming_test.exs` | Boot arming reads active records and arms per-agent time triggers (assert timer math + fire path with injected clock/`start_run_fn`); missing manifest → loud log + `mark_inactive`, no crash; no catch-up (next occurrence only). |
| `orchestrator_progress_test.exs` | Subscribe in test; stubbed stages (`provider_fn` seams) emit typed `ProgressEvent`s: started/finished per stage, verdicts, terminal deployed/blocked/stopped; events carry the run_id; persisted `PipelineRun` contains run_id + everything needed to reconstruct. |

Existing orchestrator/stage/gateway tests must stay green; any test relying on
ungated dispatch gets updated to seed the registry (fix-all-failures rule).

## Complexity Tracking

*No constitution violations — table intentionally empty.*
