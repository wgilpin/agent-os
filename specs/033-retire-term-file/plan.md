# Implementation Plan: Retire Term-File State Store

**Branch**: `033-retire-term-file` | **Date**: 2026-07-02 | **Spec**: [/specs/033-retire-term-file/spec.md](file:///Users/will/projects/agent_os/specs/033-retire-term-file/spec.md)
**Input**: Feature specification from `/specs/033-retire-term-file/spec.md`

## Summary

This plan retires the legacy Erlang term-file backend underneath the `AgentOS.StateStore` GenServer. It introduces a map/key-value table storage mode inside the SQLite backend (using `exqlite`), migrates all 8 config mounts onto it, and purges all legacy term-file load, write, and serialization references.

## Technical Context

**Language/Version**: Elixir 1.15+ / OTP 26+  
**Primary Dependencies**: `exqlite` package, `Jason` package  
**Storage**: SQLite database files on disk (replacing `.term` files with `.db` files)  
**Testing**: ExUnit (in-memory SQLite connection for tests)  
**Target Platform**: BEAM virtual machine  
**Project Type**: library/control-plane substrate  
**Performance Goals**: O(1) single-key write scaling, fast snapshot compilation.  
**Constraints**: Fully preserves the single-writer GenServer mailbox serialization and `snapshot/1` / `apply_action/2` caller contracts.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Simplicity First)**: Passed. Unifies all persistence onto a single SQLite engine, deleting complex duplicate file writers.
- **Principle II (Explicit Scope Control)**: Passed. Focuses solely on retiring the term-file. Does not add new store query connectors.
- **Principle V (Strong Typing)**: Passed. Preserves all specifications and types.
- **Principle IX (Substrate Owns State & Lifecycle)**: Passed. Preserves the single-writer GenServer lifecycle owner pattern.

## Project Structure

### Documentation (this feature)

```text
specs/033-retire-term-file/
├── plan.md              # This file
├── research.md          # SQLite UPSERT queries and key-value mapping logic
├── data-model.md        # Database schema for map store
├── quickstart.md        # Walkthrough of verification
└── tasks.md             # Actionable tasks
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── application.ex             # [MODIFY] Change config mount paths from .term to .db extension
    └── state_store.ex             # [MODIFY] Implement map/key-value storage mode, delete term-file loaders and writes

test/
└── agent_os/
    └── state_store_test.exs       # [NEW] Verify SQLite map operations, crash durability, and performance
```

**Structure Decision**: Single project structure matching current patterns.

## Complexity Tracking

*No violations identified.*
