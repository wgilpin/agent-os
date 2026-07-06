# Implementation Plan: File Connectors

**Branch**: `035-file-connectors` | **Date**: 2026-07-06 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/035-file-connectors/spec.md)
**Input**: Feature specification from `/specs/035-file-connectors/spec.md`

## Summary

Add `file_read` and `file_write` connectors to read/write local files securely. Agents interact via logical handles, while the substrate enforces access and resolves real paths based on a new agent-invisible `:path` binding on the `Grant` struct.

## Technical Context

**Language/Version**: Elixir (Erlang/OTP)
**Primary Dependencies**: None (Standard Library)
**Storage**: Local Filesystem
**Testing**: ExUnit (mocked with injected test root)
**Target Platform**: Linux server/BEAM
**Project Type**: Substrate Kernel Extension
**Performance Goals**: Minimal overhead for file I/O
**Constraints**: Absolute path hiding from the agent; loud failures on I/O errors; atomic writes.
**Scale/Scope**: 2 new modules, 1 struct field addition, no external dependencies.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Simplicity First**: Passed. Utilizing standard `File` module; no third-party libraries. Handle-based resolution requires no complex path-traversal prevention logic in the Gate.
- **IV. No Live Dependencies in Tests**: Passed. Tests will use a temporary test root directory, strictly local filesystem.
- **VI. Loud Failures**: Passed. `file_write` guarantees returning `{:error, reason}` on I/O failures.
- **VIII. Legibility Is Non-Negotiable**: Passed. The capability render will display the real path for human auditability, while hiding it from the agent.
- **X. No Ambient Authority**: Passed. The real path is bound in the `Grant` by the substrate/author, not by the agent. Agents only use logical handles.
- **XI. The Deterministic Gate Is the Only Firewall**: Passed. The gate continues to match on handles and connectors; no new gate logic is needed since paths are hidden.

## Project Structure

### Documentation (this feature)

```text
specs/035-file-connectors/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── tasks.md             # Phase 2 output (created by /speckit-tasks)
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── connector/
    │   ├── file_read.ex
    │   └── file_write.ex
    └── manifest/
        └── grant.ex

test/
└── agent_os/
    └── connector/
        ├── file_read_test.exs
        └── file_write_test.exs
```

**Structure Decision**: Elixir kernel extension following existing `AgentOS.Connector` and `AgentOS.Manifest.Grant` layout.

## Complexity Tracking

*No violations of the Constitution to justify.*
