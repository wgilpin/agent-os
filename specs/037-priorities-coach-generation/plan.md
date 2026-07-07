# Implementation Plan: Priorities Coach E2E Generation

**Branch**: `[037-priorities-coach-generation]` | **Date**: 2026-07-06 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/037-priorities-coach-generation/spec.md`

## Summary

Generate, deploy, and live-smoke the Priorities Coach through the unchanged six-stage pipeline, proving world-B holds against the machine-written agent with the new grant shapes (path grants, static discord notify credentials, and composite message+time triggers).

## Technical Context

**Language/Version**: Elixir (BEAM)
**Primary Dependencies**: Existing `AgentOS.Pipeline.Orchestrator`, ExUnit
**Storage**: N/A for generation (existing term-file/markdown)
**Testing**: ExUnit (`world_b_generated_test.exs`)
**Target Platform**: BEAM / local system
**Project Type**: Backend orchestrator / test suite
**Performance Goals**: N/A
**Constraints**: Zero live network calls and zero Docker dependencies in generation tests (Constitution IV). Must enforce all invariants without changing Gate.
**Scale/Scope**: E2E pipeline for 1 complex agent (Priorities Coach).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Simplicity First**: Uses existing pipeline stages and test suites. No new abstractions introduced.
- **IV. No Live Dependencies in Tests**: Generation and orchestration tests must run with injected provider/effector stubs.
- **VIII. Legibility**: The generated `PipelineRun` records per-stage outcome and provenance.
- **IX. Substrate Owns State**: Uses the substrate's exact event handling mechanisms.
- **X. No Ambient Authority**: Verifies that the new grant types (path-bound file access, static credential notify) are correctly isolated and enforced without agent self-conferral.
- **XI. Deterministic Gate Is Only Firewall**: Ensures Gate handles the new grant shapes correctly.
- **XII. Enforcement Precedes Generation**: Verifies that world-B (enforcement) passes on the generated agent.

All checks pass.

## Project Structure

### Documentation (this feature)

```text
specs/037-priorities-coach-generation/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── tasks.md             # Phase 2 output (to be generated)
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    └── pipeline/
        └── orchestrator.ex

test/
└── agent_os/
    └── world_b_generated_test.exs
```

**Structure Decision**: Single project (Elixir kernel). Modifications will primarily be localized to tests and pipeline configuration or stubs to accommodate the new trigger/grant combinations if the current projection lacks support.

## Complexity Tracking

No violations.
