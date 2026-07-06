# Tasks: File Connectors

**Input**: Design documents from `/specs/035-file-connectors/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure
*(No specific setup tasks required as the project structure already exists)*

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T001 Add `:path` field to `AgentOS.Manifest.Grant` struct in `lib/agent_os/manifest/grant.ex`

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Securely Reading a Granted Document (Priority: P1) 🎯 MVP

**Goal**: An agent securely reads a document by handle, with the substrate resolving the real path.

**Independent Test**: Setting up a `file_read` grant for a test file and asserting the connector's `execute/2` returns its contents, hiding the actual path.

### Tests for User Story 1

- [x] T002 [P] [US1] Create unit tests for `FileRead` connector in `test/agent_os/connector/file_read_test.exs`

### Implementation for User Story 1

- [x] T003 [P] [US1] Create `FileRead` connector module in `lib/agent_os/connector/file_read.ex`
- [x] T004 [US1] Implement `metadata/0` and `render/1` in `lib/agent_os/connector/file_read.ex`
- [x] T005 [US1] Implement `execute/2` in `lib/agent_os/connector/file_read.ex` to read from the bound path

**Checkpoint**: User Story 1 is fully functional and testable independently.

---

## Phase 4: User Story 2 - Securely Modifying a Granted Document (Priority: P1)

**Goal**: An agent securely writes back to a document by handle, with the substrate resolving the real path and writing atomically.

**Independent Test**: Setting up a `file_write` grant and asserting `execute/2` writes the new content atomically and correctly handles I/O errors.

### Tests for User Story 2

- [x] T006 [P] [US2] Create unit tests for `FileWrite` connector in `test/agent_os/connector/file_write_test.exs`

### Implementation for User Story 2

- [x] T007 [P] [US2] Create `FileWrite` connector module in `lib/agent_os/connector/file_write.ex`
- [x] T008 [US2] Implement `metadata/0` and `render/1` in `lib/agent_os/connector/file_write.ex`
- [x] T009 [US2] Implement atomic `execute/2` (tmp + rename) in `lib/agent_os/connector/file_write.ex`

**Checkpoint**: Both File Connectors are independently functional.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [x] T010 [P] Format code with `mix format` across modified files
- [x] T011 Run full test suite `mix test` to ensure World-B gate enforcement tests remain green

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: N/A
- **Foundational (Phase 2)**: T001 must be completed first to add the `:path` field to the Grant struct.
- **User Stories (Phase 3+)**: US1 and US2 can proceed in parallel since they don't depend on each other's modules.
- **Polish (Final Phase)**: Depends on all desired user stories being complete.

### Parallel Opportunities

- T003 and T007 can be created in parallel.
- Tests (T002, T006) can be written in parallel.

---

## Implementation Strategy

### Incremental Delivery

1. Complete Foundational Phase (T001).
2. Implement User Story 1 (FileRead) to establish the basic path-resolution pipeline.
3. Validate and demo User Story 1.
4. Implement User Story 2 (FileWrite) for the mutation capabilities.
5. Final polish and verify gate checks remain green.
