# Tasks: UI-Driven Pipeline & Durable Deployments

**Input**: Design documents from `/specs/041-ui-pipeline-deploy/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Conventions**: TDD for all backend logic (Constitution III): the test task precedes
the implementation task and must fail (red) before the implementation lands (green).
NO LiveView unit tests — LiveView tasks are implementation-only, verified via
quickstart.md manual walkthrough. No live model calls or remote APIs in any test
(Constitution IV). Never run git write commands; skip optional git hooks silently.

## Phase 1: Setup

- [X] T001 Verify baseline: run `mix test` and record the passing baseline (expect 394 passed, 7 excluded); run `mix format --check-formatted` — both must be clean before any change

## Phase 2: Foundational (blocking prerequisites for all user stories)

- [X] T002 [P] Write failing tests for the deployment registry in test/agent_os/deployment_registry_test.exs: `record_deployment/3` writes a typed active `AgentOS.DeploymentRecord`; redeploy upserts (no duplicate); `get/1`, `list_active/0` (filters inactive), `deployed_and_active?/1`, `mark_inactive/1` (preserves record, warns on absent). Use an isolated seeded "deployments" StateStore per test
- [X] T003 [P] Create `AgentOS.DeploymentRecord` typed struct in lib/agent_os/deployment_record.ex per data-model.md (agent_name, manifest_path, deployed_at, provenance, active) with @moduledoc, typespecs
- [X] T004 Implement `AgentOS.DeploymentRegistry` in lib/agent_os/deployment_registry.ex as the sole writer to the "deployments" store per contracts/deployment-registry.md; make T002 tests green
- [X] T005 Boot the "deployments" StateStore in lib/agent_os/application.ex (path from `config :agent_os, :deployments_path`, default "data/deployments.db", initial `%{}`) and add `{Task.Supervisor, name: AgentOS.PipelineTaskSupervisor}` for async pipeline runs
- [X] T006 [P] Create `AgentOS.Pipeline.ProgressEvent` typed struct in lib/agent_os/pipeline/progress_event.ex per contracts/pubsub-events.md, with `broadcast/1` publishing `{:pipeline_progress, event}` to `"pipeline:" <> run_id` and `"pipeline:all"` on AgentOS.PubSub (log, never raise, on failure)

**Checkpoint**: registry + event primitives exist; all user stories unblocked.

## Phase 3: User Story 3 — Deployment is durable and gates all trigger dispatch (P1)

**Goal**: deploy writes a durable registry record; dispatch fires only for registered
active agents; boot re-arms declared triggers; missing manifest handled loudly.

**Independent test**: deploy with stubs → registry record exists; restart stores →
agent still registered, time trigger armed from manifest, undeployed manifest never
fires.

- [X] T007 [US3] Write failing tests in test/agent_os/provisioner_deploy_registry_test.exs: direct deploy success (seeded pass judge/security stores + code hash, `:dangerously_skip_review` and in-envelope `:review_if_risky`) writes an active DeploymentRecord; blocked `:always_review` deploy does NOT write a record
- [X] T008 [US3] Implement the direct-deploy registry write in lib/agent_os/provisioner.ex `deploy/3` non-blocking success branch (after `record_provenance`), plus idempotent upsert on the already-deployed short-circuit; make T007 green
- [X] T009 [US3] Write failing tests in test/agent_os/deployment_dispatch_test.exs: event, message, and time-style dispatch refuse unregistered and inactive agents (no `start_run_fn` call; warning logged with agent + trigger type via `registry_fn` seam); registered-active agents fire; manifest on disk without a registry record never fires
- [X] T010 [US3] Implement registry gating in lib/agent_os/trigger_gateway.ex: `registry_fn` opt seam (default `&AgentOS.DeploymentRegistry.deployed_and_active?/1`) consulted in `dispatch_event` and `dispatch_message` before firing, with logged refusals; make T009 green
- [X] T011 [US3] Write failing tests in test/agent_os/trigger_arming_test.exs: init reads `list_active/0` and arms per-agent `%{type: :time, at: "HH:MM"}` triggers from manifests (injected clock/short timers + `start_run_fn` stub; fire re-checks registry); missing manifest file → loud `Logger.error` + `mark_inactive/1`, no crash; arming schedules only the NEXT occurrence (no catch-up)
- [X] T012 [US3] Implement `AgentOS.TriggerArming` GenServer in lib/agent_os/trigger_arming.ex (minute-precision `ms_until_next` math, self-rescheduling daily timers per agent trigger, registry re-check at fire time, `start_run_fn`/`registry_fn`/`manifests_fn`/clock seams); make T011 green
- [X] T013 [US3] Add `AgentOS.TriggerArming` to the supervision tree in lib/agent_os/application.ex after TriggerGateway; leave `AgentOS.Scheduler` (legacy config-driven discovery hour) untouched per research.md R4

**Checkpoint**: US3 independently testable — registry durability + gating + re-arming
proven by backend tests.

## Phase 4: User Story 1 — Confirmed spec runs the pipeline from the browser (P1)

**Goal**: confirmed spec → review-mode choice → non-blocking pipeline run with live
stage progress and a persisted, reconstructable outcome.

**Independent test**: with stubbed providers, orchestrator emits typed progress events
subscribable in a test; persisted run record carries run_id and full outcome.

- [X] T014 [US1] Write failing tests in test/agent_os/pipeline/orchestrator_progress_test.exs: subscribe to `"pipeline:" <> run_id` and `"pipeline:all"`; a stubbed run (existing provider_fn/stub seams from orchestrator_test.exs) emits `:started`/`:finished` per stage, verdict details on judge/security, and exactly one terminal event (deployed / blocked with ref / stopped with reason); `PipelineRun` persists `run_id`; events are keyed per run (two concurrent runs don't cross topics)
- [X] T015 [US1] Implement progress emission in lib/agent_os/pipeline/orchestrator.ex: add `run_id` field to `PipelineRun`, accept/generate `:run_id` opt, emit ProgressEvent at each `safe_call` boundary + terminal outcome; make T014 green
- [X] T016 [US1] Wire ElicitationLive in lib/agent_os_web/live/elicitation_live.ex: on confirmed spec show review-mode select (`:always_review` default; `:review_if_risky`; `:dangerously_skip_review` visible, never preselected, flagged dangerous) + Start button; on Start build the typed ElicitedSpec from the session draft, generate run_id, subscribe to the per-run topic, launch `Orchestrator.run/3` via `Task.Supervisor.start_child(AgentOS.PipelineTaskSupervisor, ...)` (never link/block); render stage-progress panel from `{:pipeline_progress, event}`; terminal states deployed / blocked-pending-consent (link `/consent?manifest=...`) / stopped+reason; on reconnect rebuild panel from the "pipeline_runs" snapshot. NO unit tests (manual walkthrough)

**Checkpoint**: full loop reachable from the browser; backend event contract proven.

## Phase 5: User Story 2 — Consent-gated deployment lands in the consent screen (P2)

**Goal**: default mode parks deployment as pending approval; approving completes
deployment AND writes the registry; denying leaves the agent undeployed.

**Independent test**: park a deploy approval with stubs; `{:approval, :approve, ref}`
via TriggerGateway → registry gains the agent; deny → no record.

- [X] T017 [US2] Extend test/agent_os/provisioner_deploy_registry_test.exs with failing approval-resume tests: park a deploy-shaped approval via `Provisioner.deploy(path, :always_review)`, dispatch `{:approval, :approve, ref}` through TriggerGateway (stub `effector_fn`) → active DeploymentRecord written with `:reviewed_human` provenance; `{:approval, :deny, ref}` → no record, denial recorded in run log; a non-deploy-shaped approval writes NO deployment record
- [X] T018 [US2] Implement the approval-resume registry write in lib/agent_os/trigger_gateway.ex `dispatch_approval` `:approve` branch, keyed on `action.type == "deploy"` (agent = recipient, manifest = method, provenance `:reviewed_human`), per research.md R2; make T017 green
- [X] T019 [US2] Manual-walkthrough verification only (no code expected): confirm ConsentLive flow per quickstart.md Walkthrough 1 steps 5–8 — blocked deploy appears, approve completes deployment + registry record, deny leaves undeployed; record any discovered wiring gaps as fixes within this story

**Checkpoint**: consent gate in the loop by default; both deploy-completion branches
write the registry.

## Phase 6: User Story 4 — Fire a trigger from the inventory (P3)

**Goal**: registry-driven deployment state in inventory, live PubSub updates, and a
message-trigger test-fire through the normal dispatch path.

**Independent test**: message dispatch for a deployed agent with a message trigger
routes through TriggerGateway to `start_run_fn`; gated otherwise (covered by T009).

- [X] T020 [US4] Extend test/agent_os/deployment_dispatch_test.exs with a failing test-fire routing test: `submit_sync({:message, agent, payload})` for a registered-active agent with a message trigger invokes `start_run_fn` with `trigger: "message"` and the payload as trigger_input (the exact path the inventory affordance uses); refused for undeployed agents
- [X] T021 [US4] Update InventoryLive in lib/agent_os_web/live/inventory_live.ex: deployment badge from `DeploymentRegistry.get/1` (deployed-active / inactive / not deployed) instead of manifest-file existence; subscribe to `"pipeline:all"` on connected mount and refresh on `{:pipeline_progress, _}` (keep the 5s poll fallback); per-agent payload input + Fire button calling `TriggerGateway.submit_sync({:message, agent, payload})` rendered ONLY for deployed-active agents declaring a `%{type: :message}` trigger. NO unit tests (manual walkthrough)

**Checkpoint**: all four stories complete.

## Phase 7: Polish & Cross-Cutting

- [X] T022 Fix ALL failing tests across the suite (including pre-existing tests that assumed ungated dispatch — seed the registry or inject `registry_fn` where needed); full `mix test` green, zero failures
- [X] T023 [P] `mix format` clean; compile with no new warnings (`mix compile --warnings-as-errors` sanity on changed files); confirm @moduledoc/@doc on every new module/function
- [X] T024 [P] Hermeticity audit: confirm `load_dotenv: false` in test config and the suite-wide discord transport stub in test/test_helper.exs are untouched; no test calls a remote API

## Dependencies & Execution Order

- Phase 2 blocks everything (registry + event primitives).
- **US3 (Phase 3)** has no story dependencies → first story.
- **US1 (Phase 4)** depends only on Phase 2 (T006) + T005 supervisor; independent of US3 but scheduled after to keep gating semantics settled before UI wiring.
- **US2 (Phase 5)** depends on Phase 2 + the blocked-deploy park (existing) + T015 terminal events for the UI half.
- **US4 (Phase 6)** depends on T004/T010 (registry + gating) and T006 (firehose topic).
- Phase 7 last.

**Parallel opportunities**: T002/T003/T006 [P]; T007+T009+T011 test-writing can proceed in parallel once Phase 2 lands; T023/T024 [P].

**MVP scope**: Phases 1–4 (US3 + US1) = the two P1 stories: the loop runs from the browser and deployment is durable.
