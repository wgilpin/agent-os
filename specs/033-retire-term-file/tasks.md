# Tasks: Retire Term-File State Store

**Input**: Design documents from `/specs/033-retire-term-file/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- Paths assume single project at repository root (`lib/agent_os/`, `test/agent_os/`)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic verification

- [ ] T001 Verify project compiles on current branch `033-retire-term-file`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Mode selection and table creation for map store

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [ ] T002 Update `init/1` to read `:mode` option in `lib/agent_os/state_store.ex`
- [ ] T003 Update `init/1` to create the SQLite table `map_store` when mode is `:map` in `lib/agent_os/state_store.ex`

**Checkpoint**: Foundation ready - map store CRUD operations can now be implemented

---

## Phase 3: User Story 1 - Map Mode CRUD (Priority: P1) 🎯 MVP

**Goal**: Support `:put`, `:delete_in`, `:append`, and `snapshot` operations via prepared SQL queries.

**Independent Test**: Verify StateStore map operations read and write key-values in SQLite.

### Implementation for User Story 1

- [ ] T004 Implement single-key `:put` using SQL UPSERT in `lib/agent_os/state_store.ex`
- [ ] T012 Implement nested `:delete_in` and `:append` using query-decode-mutate-upsert in `lib/agent_os/state_store.ex`
- [ ] T013 Implement `snapshot` fetching and map reconstruction from SQL rows in `lib/agent_os/state_store.ex`

**Checkpoint**: Map CRUD MVP complete.

---

## Phase 4: User Story 2 - Term-File Code Deletion (Priority: P2)

**Goal**: Remove all legacy term-file load, write, and serialization references.

**Independent Test**: Audit the file and confirm zero references to term-file code exist.

### Implementation for User Story 2

- [ ] T007 Delete `:erlang.term_to_binary`, `:erlang.binary_to_term`, and temporary file rename loaders in `lib/agent_os/state_store.ex`

**Checkpoint**: Term-file code completely purged.

---

## Phase 5: User Story 3 - Config Mounts Migration (Priority: P3)

**Goal**: Repoint all system mounts onto the SQLite backend.

**Independent Test**: The system boots successfully and passes tests with all mounts using `.db` files.

### Implementation for User Story 3

- [ ] T008 Update application state store definitions and environment config paths to swap `.term` for `.db` in `lib/agent_os/application.ex`
- [ ] T009 [P] Update all ExUnit test files to swap `.term` database setups with `.db` SQLite setups in `test/agent_os/`

**Checkpoint**: All mounts migrated.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Validation and final code formatting

- [ ] T010 Create unit and integration tests verifying SQLite key-value map operations, crash recovery, and O(1) single-key writes in `test/agent_os/state_store_test.exs`
- [ ] T011 Run `mix format` and `mix test` to ensure all tests pass and the workspace is clean
