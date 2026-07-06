# Feature Specification: File Connectors

**Feature Branch**: `035-file-connectors`  
**Created**: 2026-07-06  
**Status**: Draft  
**Input**: User description: "Add file_read and file_write connectors — the first live external read (Rd) and a mutating filesystem write (Mut) — bounded by a new path-scoped manifest grant..."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Securely Reading a Granted Document (Priority: P1)

An agent needs to read a priorities document. It proposes a `file_read` action using the logical handle "priorities". The substrate safely resolves the handle to the real path based on the manifest grant and returns the document content, completely hiding the actual host path from the agent.

**Why this priority**: Reading is the fundamental prerequisite. Path-hiding and handle-resolution is the core security feature.

**Independent Test**: Can be tested by setting up a read grant for a dummy test file. The agent proposes a read action with a handle; the test verifies that the content is returned and the path remains hidden.

**Acceptance Scenarios**:

1. **Given** an agent with a `file_read` grant for handle "my_doc" mapped to path "/test/doc.md", **When** it proposes reading "my_doc", **Then** the substrate reads "/test/doc.md" and returns its contents.
2. **Given** an agent with no read grant for "secret_doc", **When** it proposes reading "secret_doc", **Then** the gate rejects the ungranted action.

---

### User Story 2 - Securely Modifying a Granted Document (Priority: P1)

An agent needs to update the priorities document. It proposes a `file_write` action with the new content and the logical handle. The substrate securely and atomically writes the new content to the actual file path without exposing it to the agent.

**Why this priority**: Writing back to documents is the second half of the core feature requirement. Atomic updates prevent corruption.

**Independent Test**: Can be tested by setting up a write grant. The agent proposes a write; the test verifies the file on disk is atomically updated.

**Acceptance Scenarios**:

1. **Given** an agent with a `file_write` grant for handle "my_doc" mapped to "/test/doc.md", **When** it proposes a write with new content, **Then** the substrate atomically writes the new content to "/test/doc.md".
2. **Given** an agent with only a `file_read` grant (no `file_write`), **When** it proposes a write, **Then** the gate rejects the action.
3. **Given** a filesystem error during a write, **When** the write action is executed, **Then** a loud error is returned and the write fails safely (no partial writes).

---

### Edge Cases

- What happens when the agent tries to write to a path directly instead of using a handle?
- How does the system handle an I/O error during read or write?
- What happens if the agent's proposed write crashes mid-write?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST support a new `:path` binding on the `Grant` struct that is substrate-controlled and agent-invisible.
- **FR-002**: System MUST provide a `file_read` connector that resolves a handle to the bound path and returns the file's contents.
- **FR-003**: System MUST provide a `file_write` connector that resolves a handle to the bound path and writes the provided content atomically (using tmp file + rename).
- **FR-004**: System MUST NOT expose real filesystem paths in proposed actions or agent-observable surfaces.
- **FR-005**: `file_write` MUST return a loud `{:error, reason}` on I/O failures, never silently failing.
- **FR-006**: The gate MUST enforce that an agent granted only `file_read` cannot execute `file_write`.
- **FR-007**: `file_read` metadata MUST declare `mutating?: false`, `requires_deploy_consent?: false`, `requires_runtime_approval?: false`, `credential: nil`.
- **FR-008**: `file_write` metadata MUST declare `mutating?: true`, `requires_deploy_consent?: true`, `requires_runtime_approval?: false`, `credential: nil`.
- **FR-009**: Capability render MUST display human-legible capability lines (e.g. "READ THE PRIORITIES DOCUMENT"), showing the real path on the human-facing surface but maintaining invisibility on the agent-facing surface.

### Key Entities

- **Grant**: Extended to include an agent-invisible `:path` property.
- **file_read Connector**: New component to handle non-mutating file reads by handle.
- **file_write Connector**: New component to handle mutating file writes by handle atomically.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Tests pass verifying that an agent can read and write files using only handles, without ever seeing or supplying a real host path.
- **SC-002**: Tests pass verifying that an ungranted handle or ungranted connector correctly results in a gate rejection.
- **SC-003**: Tests pass verifying that write operations are atomic and loud I/O errors are returned on failure.
- **SC-004**: Implementation is complete utilizing the existing dynamic discovery system, without any central registry edits or manual changes to `Gate`.
- **SC-005**: All existing world-B verification tests continue to pass without dropping or relaxing any breach cases.

## Assumptions

- The prefix + containment path traversal defense model is out of scope and deferred.
- Google Drive, OAuth, and Discord integration are out of scope.
- End-to-end deployment of the Priorities Coach is out of scope.
- File operations run against an injected root/temp directory in the test suite to ensure no network or Docker dependencies.
