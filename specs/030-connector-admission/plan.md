# Implementation Plan: Connector Admission + Compile-Isolated Plugins

**Branch**: `030-connector-admission` | **Date**: 2026-07-02 | **Spec**: [/specs/030-connector-admission/spec.md](file:///Users/will/projects/agent_os/specs/030-connector-admission/spec.md)
**Input**: Feature specification from `/specs/030-connector-admission/spec.md`

## Summary

This plan establishes the trust, compilation, and loading boundaries for third-party connectors. It implements contract isolation (T1) where connectors return described effects instead of directly mutating state, compile isolation via separate Mix apps, dynamic plugin loading from `.beam` files, and an explicit human-in-the-loop admission gate with mapped credential provisioning.

## Technical Context

**Language/Version**: Elixir 1.15+ / OTP 26+  
**Primary Dependencies**: Standard Library (`Code`, `:code`, `File`, `Path`)  
**Storage**: StateStore (`admitted_plugins.term` term-file)  
**Testing**: ExUnit  
**Target Platform**: BEAM virtual machine  
**Project Type**: library/control-plane substrate  
**Performance Goals**: <100ms dynamic load time, zero overhead for first-party paths.  
**Constraints**: First-party connectors (`kv_append`, `external_send`, `gmail_read`, `gmail_draft`, `web_search`) must run seamlessly on the pluggable path with unchanged public interfaces.  
**Scale/Scope**: 1 new StateStore ("admitted_plugins"), 1 refactored connector (`kv_append`), 1 refactored chokepoint (`effector.ex`), and helper tools.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Simplicity First)**: Passed. Reuses the standard Erlang `:code` loader for dynamic loading rather than implementing a complex custom loader.
- **Principle II (Explicit Scope Control)**: Passed. Scope is limited to phase 08-03 constraints. Does not implement marketplace or signature verification.
- **Principle V (Strong Typing)**: Passed. Defines formal types for described effects (e.g. `{:state_store, store_name, action}`).
- **Principle IX (Substrate Owns State & Lifecycle)**: Passed. Connectors no longer write directly to state stores; the effector performs mutations.
- **Principle X (No Ambient Authority)**: Passed. Connectors must be admitted and mapped to credentials by a privileged administrator prior to execution.
- **Principle XI (Gate Is Only Firewall)**: Passed. Credentials are bound at admission and resolved dynamically by `CredentialProxy` at post-approval runtime.

## Project Structure

### Documentation (this feature)

```text
specs/030-connector-admission/
├── plan.md              # This file
├── research.md          # Research notes on VM code loading and effect contracts
├── data-model.md        # Admission schema
├── quickstart.md        # Walkthrough of dynamic compilation and admission
└── tasks.md             # Actionable checklist
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── application.ex             # [MODIFY] Supervise admitted_plugins StateStore
    ├── connector.ex               # [MODIFY] Dynamic loading, admission roster validation
    ├── effector.ex                # [MODIFY] Intercept and apply described effects (Contract Isolation T1)
    ├── credential_proxy.ex        # [MODIFY] Resolve dynamic credential mappings for admitted plugins
    └── connector/
        └── kv_append.ex           # [MODIFY] Return described effect instead of calling StateStore

test/
└── agent_os/
    ├── connector_admission_test.exs # [NEW] Test dynamic loading, admission, and contract isolation
    └── support/
        └── plugins/               # [NEW] Test fixture separate compilation source
```

**Structure Decision**: Single Elixir project leveraging BEAM load path configuration.

## Complexity Tracking

*No violations identified.*
