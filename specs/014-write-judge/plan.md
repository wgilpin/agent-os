# Implementation Plan: Stage 3 Write the Judge (write-judge)

**Branch**: `014-write-judge` | **Date**: 2026-06-30 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/014-write-judge/spec.md)
**Input**: Feature specification from `/specs/014-write-judge/spec.md`

## Summary

Stage 3 of the v3 pipeline synthesizes a declarative test specification (`judge_spec.json`) from a confirmed manifest and a raw purpose string, before the agent body exists. At deploy-time, a generic substrate-side runner executes the agent (via ports/mock interfaces), records the agent's proposed actions/outputs, and evaluates them using `AgentOS.InferenceBroker` (LLM-as-judge) to certify code-matches-manifest compliance. This design enforces strict context/prompt isolation to resolve the co-generation caveat, routes all LLM calls through the metered chokepoint, and surfaces results in the standing inventory.

## Technical Context

**Language/Version**: Elixir ~> 1.20 (Control Plane), Python ~> 3.12 (Agent Workloads)  
**Primary Dependencies**: `AgentOS.InferenceBroker`, `AgentOS.StateStore`, `jason`  
**Storage**: Substrate state store (`AgentOS.StateStore`) + local filesystem (`agents/<agent_name>/judge_spec.json`)  
**Testing**: `ExUnit` (Elixir unit/integration tests with deterministic mocks)  
**Target Platform**: BEAM / OTP  
**Project Type**: Control plane compiler/synthesis module  
**Performance Goals**: Synthesis latency < 10s; evaluation latency bounded by model response speed  
**Constraints**: All LLM calls must route through the single inference chokepoint; agent must not access test spec; fail-safe on network errors  
**Scale/Scope**: Stage 3 component of the v3 pipeline  

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I: Simplicity First**: We use a declarative JSON format (`judge_spec.json`) for test cases and a single generic Elixir runner module rather than generating dynamic code.
- **Principle II: Explicit Scope Control**: The judge is scoped strictly to verifying code-matches-manifest compliance; it does not check intent or run security review.
- **Principle V: Strong Typing**: We define typed structures for test cases (`AgentOS.Pipeline.Stage3.TestCase`) and return values.
- **Principle VIII: Legibility is Non-Negotiable**: Verdicts are stored in `StateStore` and rendered in the standing inventory.
- **Principle IX: Substrate Owns State & Lifecycle**: The control plane initiates and monitors the test execution; test results live in the substrate store.
- **Principle X: No Ambient Authority**: All model calls route through `InferenceBroker` using run tokens. The agent has no access to its manifest or test spec.
- **Principle XI: Deterministic Gate Is Only Firewall**: The judge is a smoke detector; the deterministic gate remains the runtime firewall.
- **Principle XII: Enforcement Precedes Generation**: The pipeline runs Stage 3 using the manifest format verified in Phase 3.

## Project Structure

### Documentation (this feature)

```text
specs/014-write-judge/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/
│   └── judge-api.md     # Phase 1 output (/speckit-plan command)
└── checklists/
    └── requirements.md  # Spec quality checklist
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── pipeline/
    │   └── stage3_judge.ex      # NEW — Stage 3 synthesis and execution runner
    └── inventory.ex             # Modified to render judge results in inventory

test/
└── agent_os/
    └── pipeline/
        └── stage3_judge_test.exs # NEW — Unit & integration tests for Stage 3
```

**Structure Decision**: Single project (DEFAULT), adding the Stage 3 logic within the `AgentOS.Pipeline` namespace in `lib/agent_os/pipeline/stage3_judge.ex` and matching tests.

## Complexity Tracking

*No violations to justify.*
