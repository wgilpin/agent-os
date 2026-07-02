---
description: "Task list for E2E Generation MVP Thread + World-B on a Generated Agent"
---

# Tasks: E2E Generation MVP Thread + World-B on a Generated Agent

**Input**: Design documents from `/specs/027-e2e-generation-thread/`
**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/orchestrator.md](contracts/orchestrator.md), [quickstart.md](quickstart.md)

**Tests**: REQUIRED — Constitution III (Test-Driven Backend). The orchestrator is backend
logic → built test-first (red → green). World-B-on-generated IS a test. Stages run behind
injected `provider_fn`/effector stubs (Constitution IV) — zero live calls.

**Organization**: Tasks grouped by user story. US1 and US2 are both P1 and independent of
each other (US2 does not need the orchestrator). US3 is P2 and builds on US1's orchestrator.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1 / US2 / US3

## Scope guardrails (from plan.md — do NOT violate)

- No new stage logic; compose existing `Manifest.Projection`, `Pipeline.Stage3/4/5`, `Provisioner`.
- No change to `Gate`, `Provisioner.envelope_predicate?/2`, `check_deploy_on_green/2`, or review-mode semantics (FR-003, SC-007).
- The "recruiter" worked example lives in `test/fixtures/`, never in `lib/agent_os/` (Constitution IX).
- `world_b_test.exs` and `provisioner_test.exs` must stay green and unchanged (scope guard).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Substrate wiring and shared fixtures used across stories.

- [x] T001 Add a `pipeline_runs` single-writer `AgentOS.StateStore` child to the supervision tree in `lib/agent_os/application.ex`, following the exact `judge_results` / `security_review_results` pattern (name `"pipeline_runs"`, `path: Application.get_env(:agent_os, :pipeline_runs_path, "data/pipeline_runs.term")`).
- [x] T002 [P] Create the generation fixtures module `test/fixtures/generation/generation.ex` (`AgentOS.Fixtures.Generation`) exposing: `recruiter_confirmed_spec/0` (a confirmed `%AgentOS.ElicitedSpec{}` for "reply to recruiter emails"), `stub_agent_body/0` (a fixed Stage-4 `main.py`/`models.py` map), stubbed `provider_fn`s (`judge_pass/0`, `security_pass/0`, `security_fail/0`, `crashing_provider/0`), and `tmp_dirs/0` returning `%{spec_dir:, manifest_dir:}` under `System.tmp_dir!()` unique per run — so orchestrator/world-B tests write no `manifests/` or `agents/` files into the repo tree (I1 isolation, Constitution IX).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The run record and the orchestrator module shell that US1 and US3 build on.

**⚠️ CRITICAL**: No user-story work begins until this phase is complete.

- [x] T003 Create `lib/agent_os/pipeline/orchestrator.ex` with the `AgentOS.Pipeline.Orchestrator.PipelineRun` struct + typespecs per [data-model.md](data-model.md) (`agent_name`, `purpose`, `stages`, `judge_verdict`, `security_verdict`, `deploy_result`, `provenance`, `outcome`, `stopped_at`, `reason`, `started_at`, `finished_at`) and the `stage/0`, `stage_status/0`, `stage_outcome/0`, `deploy_result/0` types. Struct + `@moduledoc` only — no `run/*` logic yet.
- [x] T004 In `lib/agent_os/pipeline/orchestrator.ex`, add private persistence helpers: record the `PipelineRun` via `StateStore.apply_action("pipeline_runs", {:put, agent_name, run})` and append one human-readable line per run to `AgentOS.RunLog` (Constitution VIII/IX). Called from every exit path.

**Checkpoint**: Run record + orchestrator shell exist; US1 and US3 can begin.

---

## Phase 3: User Story 1 — Confirmed purpose → deployed novel agent, human-out-of-the-loop (Priority: P1) 🎯 MVP

**Goal**: One invocation carries a confirmed `ElicitedSpec` through Stage 2 → 6 with no human input between stages, ending in a deploy decision.

**Independent Test**: From `recruiter_confirmed_spec/0`, `Orchestrator.run/2` executes stages in order (each consuming the prior's artifact) and reaches a deploy decision with zero inter-stage human input (SC-001, SC-002, US1-AS1/AS2/AS4).

### Tests for User Story 1 (write first, must FAIL) ⚠️

- [x] T005 [P] [US1] Green-path test in `test/agent_os/pipeline/orchestrator_test.exs`: given `recruiter_confirmed_spec/0` + passing judge/security stubs, `run/2` returns `{:ok, run}` with `outcome: :deployed`, both verdicts `:pass`, `provenance != nil`, and `stages` in order `[:manifest, :agent, :judge, :security_review, :deploy]` (FR-001, FR-012, SC-001, SC-002). Pass `Fixtures.Generation.tmp_dirs/0` as `spec_dir`/`manifest_dir` and register `on_exit` cleanup so the run writes nothing into the repo's `manifests/` or `agents/` (I1 isolation).
- [x] T006 [P] [US1] Threading test in `test/agent_os/pipeline/orchestrator_test.exs`: assert the Stage-2 manifest is the one passed to Stages 3/4/5 and the Stage-4 code is what Stage 5 reviews — no re-read/re-derive (FR-002); assert on-disk code exists before either verdict is produced so no verdict is `:stale_verdict` (research R2 ordering).
- [x] T007 [P] [US1] Deploy-handoff test in `test/agent_os/pipeline/orchestrator_test.exs`: on both-pass, `Provisioner.deploy/3` is invoked unchanged and its return flows into `run.deploy_result`/`run.provenance` (FR-003); the orchestrator sets no options `deploy/3` didn't already accept.

### Implementation for User Story 1

- [x] T008 [US1] Implement `Orchestrator.run/3` (and `run/2` defaulting `review_mode: :always_review`) in `lib/agent_os/pipeline/orchestrator.ex` as a `with` chain in research-R2 order: Stage 2 `Manifest.Projection.project/1` + `write/2` → Stage 4 `Stage4.generate/3` → Stage 3 `Stage3.generate/3` (blind) + `Stage3.run/2` → Stage 5 `Stage5.review/4` → Stage 6 `Provisioner.deploy/3`. Precondition: reject non-confirmed spec with `stopped_at: :manifest, reason: :spec_not_confirmed`. Thread a `:spec_dir` opt (agents base, default `"agents"`) and a `:manifest_dir` opt (default `"manifests"`) consistently to `Projection.write/2`, `Stage4` `:spec_dir`, and the `deploy/3` manifest_path + `code_hash` opts, so all filesystem writes are redirectable in tests while production defaults are unchanged (I1).
- [x] T009 [US1] Thread artifacts + accumulate `stages` outcomes; build and persist the `PipelineRun` (via T004 helpers) with `outcome: :deployed | :blocked`, mirroring `deploy/3`'s provenance (never overriding it). Return `{:ok, run}` when `outcome in [:deployed, :blocked]`.
- [x] T010 [US1] Add per-stage `Logger` transitions and `@doc` intent comments (Constitution VI/VII); ensure `opts` (`provider_fn`, stubs, `spend_threshold`) pass through untouched to each stage and `deploy/3`.

**Checkpoint**: The recruiter thread runs end-to-end to a deploy decision, human-out-of-the-loop.

---

## Phase 4: User Story 2 — Enforcement holds against an agent the OS wrote itself (Priority: P1)

**Goal**: The full spec-008 world-B battery (BC-1…BC-7) is denied by the gate against a machine-written manifest (Stage 2) + machine-written body (Stage 4).

**Independent Test**: `mix test test/agent_os/world_b_generated_test.exs` — every breach case denied; no case dropped relative to `world_b_test.exs` (SC-003, SC-004, FR-008/009/010, US2-AS1/AS2/AS3). Independent of the orchestrator (US1).

### Tests for User Story 2 (this story IS the test) ⚠️

- [x] T011 [US2] Create `test/agent_os/world_b_generated_test.exs` `setup`: obtain `manifest` from `Manifest.Projection.project/1` of `recruiter_confirmed_spec/0` (machine-written) and synthesise the body via `Stage4.generate/3` behind a stubbed `provider_fn` (machine-written), writing to `Fixtures.Generation.tmp_dirs/0` with `on_exit` cleanup (I1 isolation); reuse `AgentOS.Fixtures.WorldB.Hostile` and the connector registry (research R3).
- [x] T012 [P] [US2] Port BC-1…BC-4 (exceed grants, spoof recipient/method, exfiltrate/no-bypass + positive control, bust the dollar cap) into `world_b_generated_test.exs` verbatim in structure, retargeted at the generated `context.manifest`/`agent_name` (FR-008/011, SC-003).
- [x] T013 [P] [US2] Port BC-5…BC-7 (forge trigger, forge/self-grant approval, read the manifest) into `world_b_generated_test.exs`; BC-7 asserts the **machine-written** manifest fields are absent from every agent-bound payload yet gate-readable (FR-010, US2-AS2). Add one assertion (I3): deploy the generated agent under `:dangerously_skip_review`, then confirm a BC breach is still gate-denied at runtime — proving review-skip is deploy-only and the gate still enforces the machine-written manifest (spec Edge Case; concept invariant validate-6).
- [x] T014 [US2] Add the no-drop guard test in `world_b_generated_test.exs`: assert the count of `describe "BC-` blocks equals that in `world_b_test.exs` (SC-004, FR-009, US2-AS3) — a dropped/`@tag :skip`'d case fails the suite.

**Checkpoint**: World-B proven against a generated agent; the headline v3 acceptance holds.

---

## Phase 5: User Story 3 — A partial-failure run stops legibly and safely (Priority: P2)

**Goal**: Any red (judge fail, security fail, stage crash) stops before deploy with the failing stage attributed and readable; the run record exposes both verdicts + provenance without asking the agent.

**Independent Test**: Forced-failure runs never deploy and are attributed in the inventory; a completed run's verdicts + provenance are readable from `pipeline_runs`/`Inventory` (FR-006/007, SC-005/006, US3-AS1/AS2/AS3). Depends on US1's orchestrator.

### Tests for User Story 3 (write first, must FAIL) ⚠️

- [x] T015 [P] [US3] Judge-fail + security-fail tests in `test/agent_os/pipeline/orchestrator_test.exs`: each returns `{:error, run}` with `outcome: :stopped`, `stopped_at: :judge` / `:security_review`, `deploy/3` never called, and the failing check distinguishable in `reason` (FR-005/007, US3-AS1/AS2, SC-006; covers both Edge-case directions).
- [x] T016 [P] [US3] Stage-crash test in `test/agent_os/pipeline/orchestrator_test.exs`: a `crashing_provider/0` that raises is caught at the orchestrator boundary → `outcome: :stopped`, `stopped_at` set, logged, `deploy/3` never reached, no process leak (FR-007, US3-AS3, SC-006).
- [x] T017 [P] [US3] Legibility read-back test in `test/agent_os/pipeline/orchestrator_test.exs`: after any run, `StateStore.snapshot("pipeline_runs")[agent]` and `Inventory.render()` expose both verdicts **and** deploy provenance without invoking the agent (FR-006, SC-005, US1-AS3).

### Implementation for User Story 3

- [x] T018 [US3] In `Orchestrator.run/3`, wrap stage execution so a raise/exit is rescued/caught, logged with stage + stacktrace (Constitution VI), and recorded as `outcome: :stopped` with `stopped_at`/`reason`; short-circuit so no failing/crashing path can reach `deploy/3` (FR-007).
- [x] T019 [US3] Ensure the persisted `PipelineRun` carries `judge_verdict`, `security_verdict`, `provenance`, `stopped_at`, and `reason` for every terminal state, and that `Inventory.render/1` surfaces the run thread (extend `lib/agent_os/inventory.ex` only if the failure attribution isn't already derivable from the existing verdict/provenance rendering).

**Checkpoint**: Every red path stops before deploy, attributed and legible.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T020 [P] Run `mix format` and `mix credo`; ensure `mix dialyzer` is clean for the new struct/typespecs (Constitution V, Tech Stack gate).
- [x] T021 Scope-guard regression: `mix test test/agent_os/world_b_test.exs test/agent_os/provisioner_test.exs` pass unchanged — proves no gate/envelope/review-mode drift (SC-007).
- [x] T022 Run the full suite `mix test` (expect prior 258 + new tests green) and walk [quickstart.md](quickstart.md) steps 2–4 in IEx.
