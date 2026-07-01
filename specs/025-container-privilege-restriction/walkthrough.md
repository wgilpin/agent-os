# Walkthrough - Container Privilege Restriction (Phase 7 Hardening)

This document details the completed implementation and verification results for roadmap phase 7 container privilege restriction.

## Changes Made

### 1. Hardened Sandbox Argument Compiler
- **File**: [sandbox.ex](file:///Users/will/projects/agent_os/lib/agent_os/sandbox.ex)
- **Modifications**:
  - Defined strict resource ceilings as module constants: memory cap of 128MB (`@max_memory_mb 128`), CPU core limit of 0.5 (`@max_cpus 0.5`), max processes limit of 32 (`@pids_limit 32`), and max file descriptors of 1024:2048 (`@nofile_limit "1024:2048"`).
  - Implemented CPU parsing helper `parse_cpus/1` to cleanly parse string and numeric core inputs.
  - Implemented root user validation check to reject configurations matching uid `0` or name `root` (split on `:` and trimmed).
  - Implemented network configuration check to strictly require `--network none`.
  - Implemented resource limit validation raising `ArgumentError` if memory or CPU bounds exceed standard ceilings.
  - Added `--pids-limit` and `--ulimit nofile` flags to `base_args` array.
  - Implemented mount verification loop to force read-only (`:ro`) access for all volume bind mounts except the legitimate inference socket `/tmp/inference.sock`.

### 2. Expanded Test Coverage
- **File**: [sandbox_test.exs](file:///Users/will/projects/agent_os/test/agent_os/sandbox_test.exs)
  - Added unit tests verifying `build_argv/1` behavior for:
    - Root user config rejection (uid 0, root, multi-segment user ids, spaced inputs).
    - Unconditional emission of dropped capability flags and no-new-privileges flags.
    - CPU/Memory limit validations and resource ceiling enforcement.
    - Enforced process limit (`--pids-limit`) and open files limit (`--ulimit`) presence.
    - Network config rejection and mount-point read-only validation.
- **File**: [isolation_test.exs](file:///Users/will/projects/agent_os/test/agent_os/isolation_test.exs)
  - Added docker-gated integration test verifying that process limit restrictions successfully detect and stop fork-bomb attempts.

---

## Verification Results

### Unit Tests
- Executed `mix test test/agent_os/sandbox_test.exs` verifying that all unit validations behave as expected.
- Result: **6 passed**.

### Integration Tests
- Executed `mix test test/agent_os/isolation_test.exs --include docker` validating both the memory OOM killing (exit 137) and process fork bomb termination (exit 42) in real Docker containers.
- Result: **7 passed**.

### Overall Suite
- Executed full test suite run checking that all 252 tests stay green.
- Result: **252 passed**.
