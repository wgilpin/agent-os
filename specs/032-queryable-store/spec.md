# Feature Specification: Queryable State Store (Agent-Invisible Namespaces)

**Feature Branch**: `032-queryable-store`  
**Created**: 2026-07-02  
**Status**: Draft  
**Input**: User description: "Add a queryable, append-heavy record store as a second StateStore backend, exposed via `store_append` and `store_find` connectors, with policy-bound, agent-invisible namespaces."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Opaque Record Appends (Priority: P1)

As an agent, I want to append opaque records to a store without knowing its real storage location/namespace or causing the database to rewrite previous records, ensuring O(1) append efficiency.

**Why this priority**: This is the core write capability. It allows agents to log observations, search hits, or feedback records.

**Independent Test**: Deploy an agent with `store_append` grant. Run the agent and propose a `store_append` action containing a record. Verify that the effector writes the record to the SQLite database file for the grant-resolved namespace, with O(1) write scaling.

**Acceptance Scenarios**:

1. **Given** an agent with a `store_append` grant, **When** the agent proposes a write action containing a record map, **Then** the substrate maps the action to the correct database namespace, appends the record, and returns `:ok`.
2. **Given** a store containing 10,000 records, **When** appending the 10,001st record, **Then** the disk write time is identical to the first write, indicating no rewrite of existing records.

---

### User Story 2 - Predicate Querying (Priority: P2)

As an agent, I want to query records matching field predicates (equality, comparisons, limits, ordering) to retrieve history without downloading the entire database into my context.

**Why this priority**: Core read capability. Allows agents to pull specific slices of history (e.g. "find gold prices recorded today") to limit token context bloat.

**Independent Test**: Propose a `store_find` action with query parameters (e.g. `%{field: "price", operator: ">=", value: 100}`). Verify the system returns only matching records in a structured array.

**Acceptance Scenarios**:

1. **Given** a store with multiple records, **When** an agent queries it with a predicate filter (e.g., `status = 'pending'`), **Then** the system returns only the matching records.
2. **Given** a query, **When** it specifies a limit (e.g. 5) and order (e.g. descending), **Then** the returned array respects those constraints.

---

### User Story 3 - Policy-Bound Agent-Invisible Namespaces (Priority: P3)

As a security-minded developer, I want agents to address stores using logical handles only, while the substrate mapping resolves the real namespace, preventing the agent from discovering other stores.

**Why this priority**: Enforces "No Ambient Authority" and manifest invisibility. Agents must never see or control real namespace strings.

**Independent Test**: Run an agent proposing a write to logical handle `"history"`. Verify that the substrate resolves `"history"` to the real namespace (e.g., `"test_agent_history_v1"`) and writes to that file, while the agent's environment contains no reference to `"test_agent_history_v1"`.

**Acceptance Scenarios**:

1. **Given** an agent manifest mapping logical handle `"feedback"` to namespace `"agent_feedback_prod_v2"`, **When** the agent issues a write to `"feedback"`, **Then** the write is applied to the SQLite database `"agent_feedback_prod_v2.db"`.
2. **Given** the agent run output, **When** checking logs or context, **Then** the literal namespace name `"agent_feedback_prod_v2"` is completely invisible to the agent.

---

### User Story 4 - Crash Durability (Priority: P4)

As a system operator, I want committed writes to survive sudden server restarts or crashes.

**Why this priority**: Crucial data integrity requirement.

**Independent Test**: Perform a write, simulate a crash of the database process, restart it, and verify the record is still present.

**Acceptance Scenarios**:

1. **Given** a committed write operation, **When** the GenServer process is killed, **Then** the record remains intact in the SQLite file upon supervisor restart.

---

### User Story 5 - Local inspectability (Priority: P5)

As a system administrator, I want to inspect the record store files directly using standard database tools, ensuring full legibility.

**Why this priority**: Satisfies Principle VIII (Legibility is Non-Negotiable).

**Independent Test**: Open the `.db` SQLite file with a standard CLI tool and verify tables and indices.

**Acceptance Scenarios**:

1. **Given** a created SQLite state store file, **When** an operator runs `sqlite3 data/my_store.db "SELECT * FROM records"`, **Then** the records are displayed in standard tabular form.

---

## Edge Cases

- **Malformed Predicates**: If the agent queries with an invalid predicate syntax (e.g. non-existent fields or invalid operators), the system must return a clean error without crashing.
- **Concurrent writes**: The single-writer GenServer contract must serialize concurrent writes to avoid database locks.
- **Empty Queries**: A query with no predicates must return a clean empty list or all records depending on policy, without crash.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST implement a queryable, append-heavy database backend using SQLite (`exqlite`).
- **FR-002**: The `store_append` connector MUST support appending an opaque JSON-serializable record.
- **FR-003**: The `store_find` connector MUST support querying records by equality and comparison (such as `<`, `>`, `>=`), ordering, and limit.
- **FR-004**: Namespaces MUST be policy-bound and agent-invisible; all real database file/namespace names MUST be resolved substrate-side.
- **FR-005**: The `Grant` structure MUST support a logical handle-to-namespace mapping for connectors.
- **FR-006**: The new record store MUST maintain crash-durability (WAL mode or sync write).
- **FR-007**: Safe query actions (`store_find`) MUST be read-only and classified as `:local` (no credential, no runtime approval, zero cost).
- **FR-008**: Safe write actions (`store_append`) MUST be classified as `:local`.
- **FR-009**: The record store MUST be domain-blind, treating all records as opaque maps with declared indexable properties.

### Key Entities *(include if feature involves data)*

- **Record Store Mount**: The SQLite instance bound to a specific namespace.
- **Opaque Record**: The JSON-serializable map of key-value pairs stored in the database.
- **Logical Handle / Alias**: The logical label used by the agent to address the store.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of namespace resolution occurs substrate-side; no real namespace string is visible to the agent.
- **SC-002**: Write scaling is O(1) relative to database size.
- **SC-003**: 100% of committed writes survive a simulated GenServer crash/restart.
- **SC-004**: Standard `sqlite3` CLI tool can open and query the database file successfully.

## Assumptions

- We assume that `exqlite` dependency is added to the Mix project.
- In test environments, an in-memory SQLite database can be used to satisfy the no-Docker / no-network deterministic test rule.
