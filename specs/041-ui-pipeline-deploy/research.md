# Research: UI-Driven Pipeline & Durable Deployments

All Technical Context unknowns resolved. Decisions recorded below; each deviation from
the pre-plan direction carries its rationale.

## R1 — Review-mode atoms (correction to the initial direction)

- **Decision**: Use the review modes the code actually implements:
  `:always_review | :review_if_risky | :dangerously_skip_review`
  (see `AgentOS.Provisioner.normalize_mode/1`).
- **Rationale**: The initial feature direction referenced `:skip_if_in_envelope`; no
  such atom exists. `:review_if_risky` is the envelope-aware mode (skips review only
  when the deterministic envelope predicate passes and no gate-breach flag exists).
- **Alternatives considered**: Renaming modes to match the direction — rejected;
  churns Provisioner, tests, and provenance vocabulary for zero behavior change.

## R2 — Where the approval-resume registry write lives

- **Decision**: In `AgentOS.TriggerGateway.dispatch_approval/3` (`:approve` branch),
  conditional on the parked action's `type == "deploy"`, after the effector call.
- **Rationale**: Single writer discipline requires both deploy-completion branches to
  land the record; the approval branch's completion point is the gateway, not the UI.
  Putting it in ConsentLive would make deployment durability depend on which surface
  approved it (a CLI or API approval would silently skip the registry). Keying on the
  action type prevents future non-deploy approvals from writing deployment records.
- **Alternatives considered**: (a) ConsentLive — rejected, UI-coupled; (b) inside
  `Effector.act` — rejected, the effector is generic action machinery and must stay
  agent/deployment-agnostic.

## R3 — Registry gating seam in TriggerGateway

- **Decision**: A `registry_fn` opt (default `&AgentOS.DeploymentRegistry.deployed_and_active?/1`)
  consulted in `dispatch_event` and `dispatch_message` before firing, mirroring the
  existing `manifests_fn`/`start_run_fn` seams. Time triggers are gated at arming time
  and re-checked at fire time through the same predicate.
- **Rationale**: Matches the module's established stub-seam pattern; keeps tests
  hermetic without a running store; refusals log with agent + trigger type (FR-006,
  Constitution VI).
- **Alternatives considered**: Filtering inside `default_manifests/0` — rejected; that
  helper is also used for "what exists on disk" semantics (inventory-adjacent), and
  gating must be explicit and observable per dispatch, not hidden in a loader.

## R4 — Legacy discovery schedule: keep, don't migrate

- **Decision**: Leave `AgentOS.Scheduler` (global config `run_hour` → daily discovery
  run) untouched. Add per-agent time-trigger arming as a NEW module
  (`AgentOS.TriggerArming`) beside it.
- **Rationale**: The spec allows either "keep working" or "explicitly migrate";
  keeping is strictly smaller (Constitution I) and zero-risk to the only
  currently-scheduled agent. Discovery is not registry-deployed today; forcing it
  through the registry would require a synthetic deployment record — new scope.
  Explicitly noted here per the spec's "no silent regression" edge case.
- **Alternatives considered**: Generalizing Scheduler to N agents — rejected for this
  feature; it conflates the legacy config path with the manifest path and risks the
  existing behavior. Migration remains an explicit follow-up.

## R5 — Pipeline run addressability (run_id) vs store keying

- **Decision**: Add a `run_id` field to `PipelineRun`; keep the `"pipeline_runs"`
  store keyed by agent_name.
- **Rationale**: Refresh/reconnect needs "the latest run for this agent," which the
  agent_name key already answers; the run_id inside the record lets the UI re-subscribe
  to the right topic and discard stale events. Re-keying the store by run_id would
  break existing readers (InventoryLive-adjacent tooling, tests) for no user-visible
  gain in a single-user prototype.
- **Alternatives considered**: Keying by run_id with an agent index — rejected as
  premature complexity (Constitution I).

## R6 — Progress transport: Phoenix.PubSub topics

- **Decision**: Reuse the dormant `AgentOS.PubSub`. Two topics: `"pipeline:" <> run_id`
  (per-run, ElicitationLive) and `"pipeline:all"` (firehose, InventoryLive). Message
  shape `{:pipeline_progress, %ProgressEvent{}}`.
- **Rationale**: PubSub is already in the supervision tree and unused — zero new
  dependencies (spec assumption "reuses the substrate's existing pub/sub facility").
  Typed struct payload satisfies FR-010.
- **Alternatives considered**: GenServer subscriptions / Registry-based fanout —
  rejected; reimplements PubSub.

## R7 — Async pipeline start from the LiveView

- **Decision**: A new named `Task.Supervisor` (`AgentOS.PipelineTaskSupervisor`) in the
  application tree; ElicitationLive uses `Task.Supervisor.start_child/2` (fire-and-
  forget, not linked to the LV process).
- **Rationale**: The pipeline must survive the browser session (FR-003 reconnect
  semantics) — a linked/awaited task would die with the LiveView. Reusing
  `AgentOS.ConnectorSupervisor` was considered but rejected: it is scoped to connector
  executions and mixing concerns muddies supervision semantics for a one-line child
  spec.
- **Alternatives considered**: `Task.async` in the LV — rejected (links, blocks
  termination); a dedicated GenServer pipeline runner — rejected (YAGNI; the
  orchestrator is already synchronous and re-entrant per run).

## R8 — No catch-up of missed time windows

- **Decision**: Arming always computes the NEXT occurrence from "now"; nothing scans
  for windows missed while powered off.
- **Rationale**: Spec assumption and SC-003 (zero catch-up firings). Deterministic and
  simple; matches the existing `Scheduler.ms_until_next/2` semantics.

## R9 — Missing manifest for an active registry record at boot

- **Decision**: `Logger.error` with agent name + path, `DeploymentRegistry.mark_inactive/1`,
  continue boot.
- **Rationale**: Spec edge case verbatim ("logged loudly, agent marked inactive rather
  than crashing boot or silently skipping"); Constitution VI (loud failures) forbids
  silence, IX/VIII favor the registry reflecting reality.

## R10 — Test hermeticity

- **Decision**: All new tests use isolated seeded StateStores (per-test names/paths as
  existing tests do), stub seams (`start_run_fn`, `manifests_fn`, `effector_fn`,
  `registry_fn`, `provider_fn`), and injected clocks/short timers for arming tests.
  `load_dotenv: false` and the suite-wide discord transport stub in
  `test/test_helper.exs` are untouched.
- **Rationale**: Constitution IV; explicit hard rule for this feature.
