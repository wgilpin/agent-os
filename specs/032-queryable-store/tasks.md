# Tasks: Queryable State Store (Agent-Invisible Namespaces)

**Input**: Design documents from `/specs/032-queryable-store/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- Paths assume single project at repository root (`lib/agent_os/`, `test/agent_os/`)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and dependency config

- [ ] T001 Add `exqlite` dependency to `mix.exs` and ensure project compiles on current branch `032-queryable-store`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Data model and parser changes for handles/namespaces

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [ ] T002 Add `:grant_resolved_namespace` field to `ProposedAction` in `lib/agent_os/proposed_action.ex`
- [ ] T003 Add `:handle` and `:namespace` fields to `Manifest.Grant` in `lib/agent_os/manifest/grant.ex`
- [ ] T004 [P] Update manifest parser to support handle/namespace keys in `lib/agent_os/manifest.ex`
- [ ] T005 Update `evaluate/4` to resolve namespace and populate `ProposedAction` in `lib/agent_os/gate.ex`

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - SQLite Backend & Append (Priority: P1) 🎯 MVP

**Goal**: Support SQLite DB creation and O(1) record appends.

**Independent Test**: Verify record append returns `:ok` and writes to sqlite on disk.

### Implementation for User Story 1

- [ ] T006 Update `AgentOS.StateStore` to initialize SQLite connection and create records table in `lib/agent_os/state_store.ex`
- [ ] T007 Update `AgentOS.StateStore` to process append actions using prepared SQL inserts in `lib/agent_os/state_store.ex`
- [ ] T008 [P] [US1] Implement `store_append` connector behaviour module in `lib/agent_os/connector/store_append.ex`

**Checkpoint**: Record append MVP complete.

---

## Phase 4: User Story 2 - Predicate Querying (Priority: P2)

**Goal**: Support querying records using field predicates via SQL json_extract.

**Independent Test**: Verify `store_find` returns matching records based on comparison operators.

### Implementation for User Story 2

- [ ] T009 Implement SQL query builder parsing comparison operators and limits in `lib/agent_os/state_store.ex`
- [ ] T010 [P] [US2] Implement `store_find` connector behaviour module in `lib/agent_os/connector/store_find.ex`

**Checkpoint**: Querying functionality complete.

---

## Phase 5: User Story 3 - Policy-Bound Agent-Invisible Namespaces (Priority: P3)

**Goal**: Enforce namespace lookup and isolation at Effector.

**Independent Test**: Verify that the agent uses logical handles, and real namespaces remain invisible.

### Implementation for User Story 3

- [ ] T011 Refactor `AgentOS.Effector` to resolve namespace mapping from grants and execute writes using resolved namespaces in `lib/agent_os/effector.ex`

**Checkpoint**: Namespace isolation complete.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Validation and final code formatting

- [ ] T012 Create integration tests covering SQLite database initialization, WAL settings, query predicates, and crash durability in `test/agent_os/queryable_store_test.exs`
- [ ] T013 Run `mix format` and `mix test` to ensure all tests pass and are clean
