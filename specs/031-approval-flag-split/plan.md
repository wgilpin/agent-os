# Implementation Plan: Approval Flag Split

**Branch**: `031-approval-flag-split` | **Date**: 2026-07-02 | **Spec**: [/specs/031-approval-flag-split/spec.md](file:///Users/will/projects/agent_os/specs/031-approval-flag-split/spec.md)
**Input**: Feature specification from `/specs/031-approval-flag-split/spec.md`

## Summary

This plan splits the legacy `requires_approval?` connector capability flag into two orthogonal booleans: `requires_deploy_consent?` (evaluated at build-time/deployment) and `requires_runtime_approval?` (evaluated per-call at runtime). This prevents safe but egress-oriented connectors from nagging users at runtime while still securing build-time consent.

## Technical Context

**Language/Version**: Elixir 1.15+ / OTP 26+  
**Primary Dependencies**: Standard Library, LiveView  
**Storage**: N/A (metadata change only)  
**Testing**: ExUnit  
**Target Platform**: BEAM virtual machine  
**Project Type**: library/control-plane substrate  
**Performance Goals**: Zero runtime latency change.  
**Constraints**: Hard cutover: completely remove `requires_approval?` from code, specs, and tests.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Simplicity First)**: Passed. Straightforward structural split of a flag without introducing complex state machines.
- **Principle II (Explicit Scope Control)**: Passed. Scope is limited to the flag split. Does not implement notification logic or new connectors.
- **Principle V (Strong Typing)**: Passed. Updates the behaviour callback specs.
- **Principle VIII (Legibility is Non-Negotiable)**: Passed. Both flags are rendered in the standing capability rendering view.
- **Principle X (No Ambient Authority)**: Passed. Deployment consent and runtime approval gates are strictly enforced substrate-side.

## Project Structure

### Documentation (this feature)

```text
specs/031-approval-flag-split/
├── plan.md              # This file
├── research.md          # Research findings and file audit
├── data-model.md        # Extended metadata schemas
├── quickstart.md        # Manual verification instructions
└── tasks.md             # Implementation tasks
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── connector.ex               # [MODIFY] Change requires_approval? to requires_deploy_consent? / requires_runtime_approval?
    ├── gate.ex                    # [MODIFY] Check requires_runtime_approval? for parking
    ├── provisioner.ex             # [MODIFY] Check requires_deploy_consent? inside deploy checks / envelope predicate
    ├── capability_render.ex       # [MODIFY] Render distinct badges for both flags
    └── connector/
        ├── external_send.ex       # [MODIFY] Update metadata flags
        ├── gmail_draft.ex         # [MODIFY] Update metadata flags
        ├── gmail_read.ex          # [MODIFY] Update metadata flags
        └── kv_append.ex           # [MODIFY] Update metadata flags

test/
└── agent_os/
    ├── capability_render_test.exs # [MODIFY] Update tests to verify new badges
    ├── connector_test.exs         # [MODIFY] Update connector mock tests
    ├── gate_test.exs              # [MODIFY] Update gate checks
    ├── provisioner_test.exs       # [MODIFY] Update deployment / consent checks
    └── run_supervisor_test.exs    # [MODIFY] Update mock connector manifests
```

**Structure Decision**: Single project structure matching current workspace patterns.

## Complexity Tracking

*No violations identified.*
