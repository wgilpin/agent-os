# Research: Container Privilege Restriction (Phase 7 Hardening)

This document records the design decisions and research findings for the container privilege restriction implementation.

## Decisions

### 1. Process Limitation (Fork-bomb protection)
- **Decision**: Set a fixed `--pids-limit` of `32`.
- **Rationale**: The Python agents are single-threaded workloads doing simple I/O tasks. A limit of 32 is sufficient for Python initialization, garbage collection, and any helper subprocesses while actively preventing fork-bomb attacks from exhausting host PID resources.
- **Alternatives considered**: Larger limits like `100` or `250` (unnecessary and reduces security margin), or dynamic scaling (overcomplicates the control plane).

### 2. File Descriptor Limits
- **Decision**: Set `--ulimit nofile=1024:2048`.
- **Rationale**: Sets the soft limit to `1024` and hard limit to `2048`. This protects the host from file descriptor exhaustion attacks while ensuring the agent has plenty of capacity for standard operations.
- **Alternatives considered**: High limits like `65536` (standard for web servers but unsafe for isolated agents), or a single hard-capped `1024`.

### 3. Root User Detection
- **Decision**: Verify the user string by splitting it on the colon (`:`) character. If the first part (the user name or UID) is `"0"` or `"root"`, reject the execution.
- **Rationale**: Docker accepts various formats for the `--user` flag: `uid`, `uid:gid`, `username`, `username:groupname`. Restricting any user starting with `0` or `root` prevents any run from executing as root inside the container.
- **Alternatives considered**: Relying on container runtime behavior (insufficient, as we want a loud fail before container creation).

### 4. Mount Volume Write Surface Reduction
- **Decision**: Inspect the list of mounts passed to the sandbox. Only allow read-write access for the designated inference socket mount point (`/tmp/inference.sock`). Any other mount must have `:ro` appended to the container path, otherwise execution is rejected.
- **Rationale**: Under Docker, volume mounts are writeable by default. Forcing `:ro` on all mounts other than the communication socket ensures that the read-only root filesystem constraint cannot be bypassed by mounting writable host directories.
- **Alternatives considered**: Completely banning all other mounts (too restrictive if future read-only data mounts are needed).
