# Research: File Connectors

## Findings

1. **Path Isolation via Handle Resolution**:
   - **Decision**: The substrate maps logical handles provided by the agent to actual system paths, completely insulating the agent from physical paths.
   - **Rationale**: Strict adherence to Constitution Principle X (No Ambient Authority). The manifest binds the authority (a specific file path) to a handle. The agent can only refer to the handle.
   - **Alternatives considered**: Prefix + containment (where agent supplies relative path and substrate validates). Rejected because the `Priorities Coach` use case only requires a single document, making handle resolution both sufficient and strictly safer.

2. **Atomic Writes**:
   - **Decision**: The `file_write` connector will write content to a temporary file in the same directory as the target, then perform an atomic `File.rename/2`.
   - **Rationale**: Prevents data corruption or truncation if the system crashes mid-write.

3. **Gate Checking**:
   - **Decision**: No changes to `AgentOS.Gate`. The existing `g.handle == action_handle` logic flawlessly supports this mechanism.
