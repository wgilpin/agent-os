# Implementation Plan: Container Privilege Restriction

**Branch**: `025-container-privilege-restriction` | **Date**: 2026-07-01 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/025-container-privilege-restriction/spec.md)
**Input**: Feature specification from `/specs/025-container-privilege-restriction/spec.md`

## Summary

Enforce non-weakening container execution restrictions inside `AgentOS.Sandbox.build_argv/1`. Define standard ceilings for memory (128MB), cpus (0.5), pids (32), and file descriptors (1024:2048) as module constants. If a caller requests resources exceeding the ceilings, network host access, a root user, or writable mounts outside `/tmp/inference.sock`, raise `ArgumentError` synchronously. Add `--pids-limit` and `--ulimit nofile` flags to all container runs.

## Technical Context

**Language/Version**: Elixir 1.15+, Python 3.11  
**Primary Dependencies**: Docker, standard library  
**Storage**: N/A (Functional argument generation)  
**Testing**: ExUnit (Elixir)  
**Target Platform**: macOS, Linux (Docker-based sandbox environments)  
**Project Type**: CLI / System Orchestrator  
**Performance Goals**: N/A (low-volume task execution)  
**Constraints**: CPU (0.5 cores max), Memory (128MB max), PIDs (32 max), Open Files (1024 max), network-isolated (`--network none`)  
**Scale/Scope**: Single-threaded Python agent workloads running as non-root users

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Simplicity)**: Pass. Uses standard Docker CLI flags and clean validation functions.
- **Principle II (Explicit Scope)**: Pass. Stays strictly inside container privilege/resource limits.
- **Principle VI (Loud Failures)**: Pass. Any configuration issue raises an `ArgumentError` exception synchronously.
- **Principle VII (Comments)**: Pass. Adding docstrings and intent comments to the updated Elixir functions.
- **Principle IX (Substrate Owns State)**: Pass. Pure functional argument compiler, no shared state or identifiers hardcoded.
- **Principle X (No Ambient Authority)**: Pass. Hardens the container runtime to strictly match the seL4 capability principles.

## Project Structure

### Documentation (this feature)

```text
specs/025-container-privilege-restriction/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
└── checklists/
    └── requirements.md  # Specification quality checklist
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── sandbox.ex       # Sandbox configurations and build_argv/1
    └── run_worker.ex    # Runtime worker execution setup

test/
└── agent_os/
    ├── sandbox_test.exs # Unit tests for argv compilation
    ├── isolation_test.exs # Integration tests (OOM, Fork-bomb)
    ├── boundary_test.exs # Boundary invariants (keep green)
    └── world_b_test.exs  # World-B invariants (keep green)
```

**Structure Decision**: Standard single Elixir project layout under `lib/` and `test/`.

## Complexity Tracking

No constitution violations or complex architecture patterns introduced.
