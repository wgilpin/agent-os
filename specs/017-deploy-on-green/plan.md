# Implementation Plan: Stage 6 Deploy-on-Green

**Branch**: `017-deploy-on-green` | **Date**: 2026-07-01 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/017-deploy-on-green/spec.md)
**Input**: Feature specification from `/specs/017-deploy-on-green/spec.md`

## Summary

Implement the Stage 6 "Deploy-on-Green" gate. This gate sits in front of the existing review-mode rail (`AgentOS.Provisioner.deploy/3`). It requires both co-generated judge (`judge_results` store) and Stage 5 security-review (`security_review_results` store) verdicts to be a pass for the exact version of the generated code artifact being deployed. If both checks pass ("green"), the deploy decision is handed to the existing review-mode rail. If either check fails, missing, or stale (code modified after review), the deploy is blocked and the failure is recorded in the standing inventory.

## Technical Context

**Language/Version**: Elixir 1.15+ (OTP 26), Python 3.11 for workload verification
**Primary Dependencies**: Standard Library, Jason (JSON parser)
**Storage**: StateStore terms (`provenance`, `judge_results`, `security_review_results`, `pending_approvals`)
**Testing**: ExUnit (Elixir tests)
**Target Platform**: BEAM / Linux server
**Project Type**: control plane/gate mechanism (Elixir)
**Performance Goals**: Low overhead gate checks (< 50ms)
**Constraints**: No database, state must be persisted via term files/StateStore, strict sandbox and manifest boundaries.
**Scale/Scope**: invocation-scoped agents.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Simplicity First)**: PASS. Gating logic added to `Provisioner.deploy/3` using existing StateStores.
- **Principle II (Explicit Scope Control)**: PASS. No features beyond deploy-on-green and logging to standing inventory.
- **Principle III (Test-Driven Backend)**: PASS. Unit tests for `deploy` safety logic and standing inventory rendering will be added to `provisioner_test.exs` and `inventory_test.exs`.
- **Principle VIII (Legibility)**: PASS. Both verdicts and the resulting deploy provenance are recorded together in the standing inventory.
- **Principle IX (Substrate Owns State)**: PASS. Results are stored in the supervised StateStore term files (`judge_results`, `security_review_results`, `provenance`).
- **Principle X (No Ambient Authority)**: PASS. Manifest grants are the agent's entire power; the manifest itself is machine-written, and not readable by the agent at runtime.
- **Principle XI (Deterministic Gate Is the Only Firewall)**: PASS. Deploy-on-green is a deterministic gate before the review-mode rail. LLM reviews are smoke detectors.

## Project Structure

### Documentation (this feature)

```text
specs/017-deploy-on-green/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── contracts/           # Phase 1 output
    └── deploy-on-green-api.md
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── provisioner.ex    # Add deploy-on-green gate checks, code version matching, and verdict retrieval
    └── inventory.ex      # Include deploy gate status and check failures in standing inventory render

test/
└── agent_os/
    ├── provisioner_test.exs  # Unit tests for deploy-on-green gating, including fail cases and review mode integration
    ├── inventory_test.exs    # Unit tests for verdict rendering
    └── world_b_test.exs      # Re-verify world-B verification with machine-written manifests
```

**Structure Decision**: Code plane additions will be done in `lib/agent_os/provisioner.ex` and `lib/agent_os/inventory.ex`. Test suites in `test/agent_os/` will be updated to verify the gating logic and world-B invariants.

## Complexity Tracking

No violations of the project constitution.
