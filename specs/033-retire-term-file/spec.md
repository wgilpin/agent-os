# Feature Specification: Retire Term-File State Store

**Feature Branch**: `033-retire-term-file`  
**Created**: 2026-07-02  
**Status**: Draft  
**Input**: User description: "Retire the term-file StateStore backend and consolidate all mounts onto the queryable backend behind the unchanged single-writer contract."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Map Contract over SQLite Backend (Priority: P1)

As a substrate component (such as `inference_broker` or `trigger_gateway`), I want the `StateStore` GenServer to support the map contract (`:put`, `:delete_in`, `:append`, and `snapshot`) using the SQLite backend, so that config mounts can read and write state key-value pairs without O(total-size) write scaling.

**Why this priority**: This is the core functional bridge. It allows existing callers of `StateStore` to migrate to the new SQLite database backend without modifying their usage patterns.

**Independent Test**: Start a `StateStore` instance configured with the SQLite map backend. Perform `:put`, `:delete_in`, `:append`, and verify that `snapshot` returns the expected reconstructed key-value map.

**Acceptance Scenarios**:

1. **Given** a SQLite-backed map store, **When** I call `apply_action(:put, "status", "active")`, **Then** the value is stored under the key `"status"`.
2. **Given** the SQLite map store, **When** calling `snapshot/1`, **Then** the GenServer queries the database and returns a copy of the fully assembled key-value map.

---

### User Story 2 - Complete Term-File Retirement (Priority: P2)

As a system maintainer, I want all legacy term-file persistence code to be completely removed from the codebase, leaving SQLite as the sole database engine.

**Why this priority**: Simplifies the maintenance surface. We get rid of the O(total-size) rewrite cost of the legacy term-file and unify code paths onto SQLite.

**Independent Test**: Audit the source code and confirm zero references to `:erlang.term_to_binary`, `binary_to_term`, or `.term` files inside `StateStore` persistence logic.

**Acceptance Scenarios**:

1. **Given** the codebase post-refactor, **When** scanning for `.term` extension or `:erlang.term_to_binary` inside `lib/agent_os/`, **Then** zero occurrences are found.

---

### User Story 3 - Mounts Consolidation (Priority: P3)

As a system operator, I want all system state mounts (`roster_trust`, `spend_ledger`, `pending_approvals`, `conformance`, `provenance`, `judge_results`, `pipeline_runs`, `security_review_results`) to run on the SQLite backend, preserving their GenServer single-writer serialized mailbox.

**Why this priority**: Final migration stage. Moves all live state to the new engine, proving that the entire control plane runs on SQLite.

**Independent Test**: Start the application and run the verification suites. Verify that all components write and read state successfully, and the world-B suite is green.

**Acceptance Scenarios**:

1. **Given** the application supervisor tree start, **When** booting the system, **Then** all standard StateStore processes mount to SQLite databases.
2. **Given** the running system, **When** executing the world-B verification suite, **Then** all tests pass green.

---

## Edge Cases

- **Key Deletions**: In map/key-value mode, when a key is deleted via `:delete_in`, it must be removed from the SQLite database so that it does not reappear in the `snapshot` reconstruction.
- **Corrupt DB recovery**: If a SQLite file is corrupt at startup, the system should log a loud error and fail-closed.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The SQLite StateStore backend MUST support the map contract: `:put`, `:delete_in`, `:append`, and `snapshot` operations.
- **FR-002**: A `:put` operation to a key MUST execute an UPSERT in SQLite, ensuring O(1) single-key write performance instead of rewriting the entire map.
- **FR-003**: The `snapshot` operation MUST reconstruct the key-value map by querying and parsing all entries for that mount from the database.
- **FR-004**: All term-file serialization (`term_to_binary`, `binary_to_term`) and `.term` file references MUST be completely removed from `lib/agent_os/state_store.ex`.
- **FR-005**: All system state mounts (`roster_trust`, `spend_ledger`, `pending_approvals`, `conformance`, `provenance`, `judge_results`, `pipeline_runs`, `security_review_results`) MUST be migrated to the new SQLite map backend.
- **FR-006**: The single-writer GenServer mailbox serialization and snapshot-by-copy semantics MUST be strictly preserved.
- **FR-007**: The system MUST perform a clean cutover with no live data migration required.

### Key Entities *(include if feature involves data)*

- **StateStore GenServer**: The single writer process managing a mount.
- **Key-Value Store**: The SQLite table containing key-value records (`mount_key TEXT PRIMARY KEY, value TEXT NOT NULL`).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of `.term` file references and term-file parsing are deleted from the codebase.
- **SC-002**: All 8 system state mounts compile and boot successfully using SQLite map mode.
- **SC-003**: The world-B test battery passes 100% green with zero remote network or Docker requirements.
- **SC-004**: Single-key updates execute with O(1) disk writes.

## Assumptions

- We assume that the existing caller APIs (`StateStore.snapshot/1` and `StateStore.apply_action/2`) remain unchanged.
- We assume that existing data files can be safely deleted on startup since no production state needs to be migrated.
