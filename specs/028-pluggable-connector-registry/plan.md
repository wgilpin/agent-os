# Implementation Plan: Pluggable Connector Registry

**Branch**: `028-pluggable-connector-registry` | **Date**: 2026-07-02 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/028-pluggable-connector-registry/spec.md)
**Input**: Feature specification from `/specs/028-pluggable-connector-registry/spec.md`

## Summary

This plan overhauls the AgentOS connector registry to support dynamic auto-discovery at boot time, replacing the hardcoded registry map and custom dispatch/rendering blocks. Every connector becomes a module adopting the `AgentOS.Connector` behaviour under `lib/agent_os/connector/`. The Effector will execute connectors in an isolated task wrapper under a dynamic supervisor, with timeboxing and generic credential resolution, ensuring full crash containment.

## Technical Context

**Language/Version**: Elixir 1.15+ / OTP 26+  
**Primary Dependencies**: Standard Library (`Task.Supervisor`, `Registry`, `Code`)  
**Storage**: In-memory Registry / ETS (no persistent DB storage)  
**Testing**: ExUnit  
**Target Platform**: BEAM virtual machine  
**Project Type**: library/control-plane substrate  
**Performance Goals**: <100ms boot/discovery overhead, execution timeboxed to 5 seconds  
**Constraints**: Must maintain exact green test results for the world-B battery; no semantic changes to `Gate.evaluate/4`.  
**Scale/Scope**: Migrating 4 existing connectors: `kv_append`, `external_send`, `gmail_read`, `gmail_draft`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Simplicity First)**: Passed. Reuses BEAM's native supervisor and runtime reflection APIs, adding no external dependencies.
- **Principle II (Explicit Scope Control)**: Passed. The scope is limited to the registry refactoring and the migration of the four existing connectors.
- **Principle V (Strong Typing)**: Passed. Defines formal behaviour callbacks and Dialyzer typespecs for the registry operations.
- **Principle IX (Substrate Owns State & Lifecycle)**: Passed. Substrate remains agent-agnostic. No domain vocabulary leaks into `lib/agent_os/`.
- **Principle XI (Gate Is Only Firewall)**: Passed. Injects credentials post-approval at the effector chokepoint.

## Project Structure

### Documentation (this feature)

```text
specs/028-pluggable-connector-registry/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── connector-behaviour.md
└── tasks.md             # Phase 2 output (/speckit-tasks command)
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── application.ex             # [MODIFY] Supervised Task.Supervisor setup
    ├── connector.ex               # [MODIFY] Behaviour definition, dynamic auto-discovery registry
    ├── effector.ex                # [MODIFY] Generic dispatch and fault-contained execution
    ├── capability_render.ex       # [MODIFY] Delegation to connector render/1 callback
    ├── credential_source.ex       # [MODIFY] Generic environment variable mapping
    ├── connector/                 # [NEW] Connector behaviour implementations
    │   ├── kv_append.ex           # [NEW] Migrated kv_append connector
    │   ├── external_send.ex       # [NEW] Migrated external_send connector
    │   ├── gmail_read.ex          # [NEW] Migrated gmail_read connector
    │   └── gmail_draft.ex         # [NEW] Migrated gmail_draft connector
    └── manifest/
        └── projection.ex          # [MODIFY] Delegation to connector scope/1 callback

test/
└── agent_os/
    └── connector_test.exs         # [NEW] Test suite for generic credential resolution and crash/timeout isolation
```

**Structure Decision**: Single Elixir/OTP project structure matching current workspace patterns.

## Complexity Tracking

*No violations identified.*
