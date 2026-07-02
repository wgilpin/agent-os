# Implementation Plan: Queryable State Store (Agent-Invisible Namespaces)

**Branch**: `032-queryable-store` | **Date**: 2026-07-02 | **Spec**: [/specs/032-queryable-store/spec.md](file:///Users/will/projects/agent_os/specs/032-queryable-store/spec.md)
**Input**: Feature specification from `/specs/032-queryable-store/spec.md`

## Summary

This plan implements a queryable, append-heavy record store backend based on embedded SQLite (`exqlite`) behind the single-writer `StateStore` GenServer contract. It adds `store_append` and `store_find` connectors that operate over policy-bound, agent-invisible namespaces resolved substrate-side.

## Technical Context

**Language/Version**: Elixir 1.15+ / OTP 26+  
**Primary Dependencies**: `exqlite` package (embedded SQLite3)  
**Storage**: SQLite database files on disk (stored under `data/store/`)  
**Testing**: ExUnit (using in-memory sqlite `:memory:` or temp database files)  
**Target Platform**: BEAM virtual machine  
**Project Type**: library/control-plane substrate  
**Performance Goals**: O(1) append writes, predicate queries resolved via SQL.  
**Constraints**: Zero network or Docker requirements in tests (in-memory SQLite satisfies Principle IV).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Simplicity First)**: Passed. SQLite (in-process) requires no database server setups. Uses JSON columns for domain-blind schema flexibility.
- **Principle II (Explicit Scope Control)**: Passed. Out of scope for key-value config migrations (reserved for 09-03).
- **Principle IX (Substrate Owns State & Lifecycle)**: Passed. Maintains the single-writer GenServer architecture.
- **Principle X (No Ambient Authority)**: Passed. Namespaces are invisible to agents and resolved strictly substrate-side from matching grants.

## Project Structure

### Documentation (this feature)

```text
specs/032-queryable-store/
├── plan.md              # This file
├── research.md          # SQLite JSON extract research and exqlite queries
├── data-model.md        # Database schema
├── quickstart.md        # Walkthrough of query actions
└── tasks.md             # Implementation tasks
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── proposed_action.ex         # [MODIFY] Add grant_resolved_namespace field
    ├── state_store.ex             # [MODIFY] Support SQLite connection, query, and append actions
    ├── manifest/
    │   └── grant.ex               # [MODIFY] Add logical handle / namespace mappings
    ├── gate.ex                    # [MODIFY] Propagate manifest grant namespace to proposed action
    └── connector/
        ├── store_append.ex        # [NEW] Opaque record append connector
        └── store_find.ex          # [NEW] Predicate query connector

test/
└── agent_os/
    └── queryable_store_test.exs   # [NEW] Unit/integration tests for SQLite append, find, and isolation
```

**Structure Decision**: Single project structure matching current patterns.

## Complexity Tracking

*No violations identified.*
