# Implementation Plan: Review Modes + Deterministic Envelope Predicate

**Branch**: `011-review-modes-envelope` | **Date**: 2026-06-30 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/011-review-modes-envelope/spec.md)
**Input**: Feature specification from `/specs/011-review-modes-envelope/spec.md`

## Summary

Implements the deploy-time rail for provisioning agents. Incorporates three review modes (`--always-review`, `--review-if-risky`, `--dangerously-skip-review`) and a deterministic envelope predicate that checks read-only status, egress capability, and spend limit. Records and renders the provenance in the standing inventory.

## Technical Context

**Language/Version**: Elixir (Erlang OTP 26+)
**Primary Dependencies**: None (OTP standard library)
**Storage**: StateStore (mount `"provenance"`, file `data/provenance.term`)
**Testing**: ExUnit (`mix test`)
**Target Platform**: BEAM/OTP
**Project Type**: control plane / deploy-time rail
**Performance Goals**: deploy check <5ms
**Constraints**: must be agent-agnostic, must not bypass runtime gate.
**Scale/Scope**: generic rail, tested with discovery agent fixture.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Simplicity First)**: PASS. Reuses existing StateStore, TriggerGateway, and approval structures.
- **Principle II (Explicit Scope Control)**: PASS. Only implements the requested review modes, envelope predicate, and provenance visibility.
- **Principle VIII (Legibility Is Non-Negotiable)**: PASS. The standing inventory is updated to display deployment provenance.
- **Principle IX (The Substrate Owns State & Lifecycle / Agent-Agnostic)**: PASS. The logic operates purely on generic manifest fields + the capability registry, keyed by the agent name read from the manifest. No agent domain concepts are hardcoded in the kernel.
- **Principle X (No Ambient Authority / Capabilities declared, never self-conferred)**: PASS. Review modes sit strictly above the runtime gate. Skipping human review does not bypass runtime enforcement. Danger is determined by the capability registry, not by the manifest writer.
- **Principle XI (The Deterministic Gate Is the Only Firewall)**: PASS. The runtime gate continues to enforce the manifest at runtime in all modes.
- **Principle XII (Enforcement Precedes Generation)**: PASS. Built and proven on the existing hand-written discovery agent without any generation pipeline or LLMs.

## Project Structure

### Documentation (this feature)

```text
specs/011-review-modes-envelope/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── deploy-rail.md   # Deploy rail interface contract
└── checklists/
    └── requirements.md  # Specification quality checklist
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── provisioner.ex   # Exposes deploy/3, envelope_predicate?/1, and records provenance
    ├── inventory.ex     # Reads and displays deployment provenance next to capability view
    ├── gate.ex          # Safety gate (remains unchanged, proving review mode is above gate)
    ├── application.ex   # Mounts the new "provenance" StateStore
    └── effector.ex      # Resumes deploy approval action

test/
└── agent_os/
    ├── provisioner_test.exs     # Unit tests for deploy/3, modes, and envelope predicate
    ├── world_b_test.exs         # Verifies that gate enforcement is active under skip-review
    └── trigger_gateway_test.exs # Verifies deploy approval resumption
```

**Structure Decision**: Single project layout matching default Elixir structure, extending existing control plane files under `lib/agent_os/` and tests under `test/agent_os/`.

## Complexity Tracking

*No current violations. The implementation reuses existing StateStore and TriggerGateway patterns.*
