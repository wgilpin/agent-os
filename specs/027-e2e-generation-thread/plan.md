# Implementation Plan: E2E Generation MVP Thread + World-B on a Generated Agent

**Branch**: `027-e2e-generation-thread` | **Date**: 2026-07-01 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/027-e2e-generation-thread/spec.md`

## Summary

Thread the six existing generation stages into one human-out-of-the-loop run, and prove
world-B holds against an agent the OS wrote itself. All stage logic, the gate, the
review-mode rail (011), and the spec-008 world-B battery already exist and pass; this
plan adds (1) a thin sequential **orchestrator** that carries a confirmed `ElicitedSpec`
through Stage 2 → Stage 6 — projecting the manifest, running the judge, synthesising the
agent body, running the security review, and handing the deploy decision to
`Provisioner.deploy/3` unchanged — recording one legible `PipelineRun` in the substrate;
and (2) a **generated-target world-B test** that re-runs the full BC-1…BC-7 battery
against a machine-written manifest (Stage 2 projection) and a machine-written agent
(Stage 4 body), with no breach case dropped or relaxed. It is glue + proof: no new stage
logic, no change to the gate, envelope predicate, or review-mode semantics.

## Technical Context

**Language/Version**: Elixir (BEAM/OTP) control plane; Python 3.13 agent workloads across the port boundary (unchanged here — no new Python)
**Primary Dependencies**: existing in-repo modules only — `AgentOS.Manifest.Projection` (Stage 2), `AgentOS.Pipeline.Stage3/4/5`, `AgentOS.Provisioner` (Stage 6 / deploy-on-green + review-mode rail 011), `AgentOS.StateStore`, `AgentOS.RunLog`, `AgentOS.Inventory`, `AgentOS.Gate`; `jason` only. No new external deps.
**Storage**: single-writer `AgentOS.StateStore` term-file + git-backed append-only markdown run-log. New collection `pipeline_runs`. No external database.
**Testing**: ExUnit. Stages run behind injected `provider_fn`/effector stubs (Constitution IV) — the orchestrator and world-B-generated tests make zero live calls. Reuse `test/fixtures/world_b/hostile.ex` and the BC-1…BC-7 describe blocks.
**Target Platform**: local BEAM node (prototype)
**Project Type**: single Elixir/OTP project (`lib/agent_os/`), Python workloads under `agents/`
**Performance Goals**: N/A — correctness/legibility milestone, not a perf milestone
**Constraints**: no new stage logic; no change to `Gate`, `envelope_predicate?/2`, or review-mode semantics; the generated-target world-B suite must contain every breach case the hand-written suite does (SC-004); worked example ("reply to recruiter emails") lives in test fixtures, never in `lib/agent_os/` (Constitution IX — substrate is agent-agnostic)
**Scale/Scope**: one new orchestrator module + one run struct + one new test module (world-B on generated) + orchestrator tests. ~2 source files, ~2 test files.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Gate | Status |
|-----------|------|--------|
| I. Simplicity First | Orchestrator is a straight-line `with` chain composing existing stage functions — no framework, no new abstraction. | ✅ Pass |
| II. Explicit Scope Control | Spec forbids new stage logic and any gate/envelope/review-mode change (FR-003/004, SC-007). Orchestrator only sequences; world-B test only retargets. | ✅ Pass |
| III. Test-Driven Backend | Orchestrator is backend logic → built test-first (red/green). World-B-generated IS a test. | ✅ Pass |
| IV. No Live Dependencies in Tests | All stages already accept injected `provider_fn`/effector stubs; orchestrator/world-B tests use them — no remote calls. | ✅ Pass |
| V. Strong Typing, No Bare Maps | New `PipelineRun` struct + typespecs on the orchestrator; no bare maps. Dialyzer clean. | ✅ Pass |
| VI. Loud Failures | Each stage transition and every stop logs with the failing stage + reason; no swallowed errors. | ✅ Pass |
| VII. Self-Documenting | `@moduledoc`/`@doc` on the orchestrator and each function; intent comments on the stage-threading block. | ✅ Pass |
| VIII. Legibility (no flag) | The `PipelineRun` (per-stage outcome, both verdicts, deploy provenance) is recorded in the standing inventory + run-log; readable without asking the agent (FR-006). | ✅ Pass |
| IX. Substrate Owns State & Lifecycle | Run recorded via single-writer `StateStore` (`pipeline_runs`) + append-only run-log. The "recruiter" example is a **test fixture**, not kernel code; the orchestrator is agent-agnostic (takes agent_name + spec, no hard-coded domain vocabulary). | ✅ Pass |
| X. No Ambient Authority | Manifest is machine-written by Stage 2, stays non-agent-readable; world-B-generated (BC-7) re-verifies this for a machine-written manifest. Orchestrator confers nothing — the gate still holds the grants. | ✅ Pass |
| XI. Gate Is the Only Firewall | Deploy still routes through `Provisioner.deploy/3` → gate; judge & security review remain smoke detectors that can only stop, never bypass. | ✅ Pass |
| XII. Enforcement Precedes Generation | v2 (enforcement) is complete and world-B-proven; this is v3 wiring built on it. World-B-generated is the explicit re-proof. | ✅ Pass |

**Result**: No violations. Complexity Tracking table not required.

## Project Structure

### Documentation (this feature)

```text
specs/027-e2e-generation-thread/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── orchestrator.md  # Phase 1 output — orchestrator + world-B-generated contract
├── checklists/
│   └── requirements.md  # From /speckit-specify
└── tasks.md             # /speckit-tasks output (NOT created here)
```

### Source Code (repository root)

```text
lib/agent_os/pipeline/
├── stage3_judge.ex          # EXISTING — Stage 3 (generate + run judge)
├── stage4_agent.ex          # EXISTING — Stage 4 (synthesise body)
├── stage5_review.ex         # EXISTING — Stage 5 (security review)
└── orchestrator.ex          # NEW — AgentOS.Pipeline.Orchestrator + PipelineRun struct

lib/agent_os/
├── manifest/projection.ex   # EXISTING — Stage 2 (project + write manifest)
├── provisioner.ex           # EXISTING — Stage 6 deploy-on-green + review-mode rail (UNCHANGED)
├── state_store.ex           # EXISTING — add `pipeline_runs` collection registration
├── run_log.ex               # EXISTING — orchestrator appends a run-thread entry
└── inventory.ex             # EXISTING — surfaces PipelineRun (extend render only if needed)

test/agent_os/pipeline/
└── orchestrator_test.exs    # NEW — green path, partial-failure stops, threading, provenance;
                             #        legibility read-back (both verdicts + provenance readable from
                             #        pipeline_runs/Inventory without asking the agent — FR-006/SC-005/US1-AS3);
                             #        stage-crash caught → outcome=:stopped, stopped_at set, deploy/3 never
                             #        reached (FR-007/US3-AS3/SC-006)

test/agent_os/
├── world_b_test.exs             # EXISTING — hand-written-agent battery (UNCHANGED)
└── world_b_generated_test.exs   # NEW — same BC-1…BC-7 against machine-written manifest + body;
                                 #        no-drop guard: BC-* case count equals world_b_test.exs
                                 #        (SC-004/FR-009/US2-AS3 — a dropped/skipped breach case fails the suite)

test/fixtures/
├── world_b/hostile.ex           # EXISTING — reuse hostile action fixtures
└── generation/                  # NEW — "reply to recruiter emails" confirmed ElicitedSpec + stubbed Stage-2/4 outputs
```

**Structure Decision**: Single Elixir/OTP project. One new source module
(`AgentOS.Pipeline.Orchestrator`, holding the `PipelineRun` struct) plus a
`pipeline_runs` StateStore collection. Two new test modules. `Provisioner`, `Gate`,
`envelope_predicate?/2`, and the review-mode rail are touched only as callers/asserted
invariants — never modified.

## Phase 0: Research — see [research.md](research.md)

Key decisions resolved there: orchestrator as a synchronous `with` chain (not a
GenServer/Saga); artifact threading via return values + StateStore verdict collections
that `Provisioner` already reads; how the world-B battery is retargeted (parameterise the
`setup` block's manifest + agent_name; the BC cases are manifest-driven Gate evaluations,
so retargeting the manifest is sufficient and no case is dropped); where the run is
recorded (`pipeline_runs` + run-log); and where the "recruiter" worked example lives
(test fixtures, per Constitution IX).

## Phase 1: Design & Contracts

- **[data-model.md](data-model.md)** — the `PipelineRun` struct (stage outcomes, judge &
  security verdicts, deploy result + provenance, failure attribution), its states, and
  the `pipeline_runs` collection shape.
- **[contracts/orchestrator.md](contracts/orchestrator.md)** — `Orchestrator.run/2..3`
  signature and result contract; the stop-before-deploy guarantees; the
  world-B-generated test contract (which BC cases, retarget rule, no-drop assertion).
- **[quickstart.md](quickstart.md)** — run the recruiter thread end-to-end and the
  generated-target world-B suite locally.
- **Agent context**: update the plan reference inside the `<!-- SPECKIT START -->` /
  `<!-- SPECKIT END -->` markers in `CLAUDE.md` (and `AGENTS.md`) to point at this plan.
