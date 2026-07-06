# Tasks: discord-notify

**Input**: Design documents from `/specs/034-discord-notify/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: The examples below include test tasks, reflecting the TDD requirement for Agent OS backend logic.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2)
- Include exact file paths in descriptions

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Create connector file structure in lib/agent_os/connector/discord_notify.ex
- [x] T002 Create connector test file structure in test/agent_os/connector/discord_notify_test.exs

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 Implement the `AgentOS.Connector` behaviour and register the module capability metadata in `lib/agent_os/connector/discord_notify.ex`.

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Live Notification Egress (Priority: P1) 🎯 MVP

**Goal**: Send a real text notification to a Discord channel via an incoming webhook using the injected credential.

**Independent Test**: Configure the system with a test transport, dispatch a notify action, and verify the correct POST payload was sent.

### Tests for User Story 1 ⚠️

> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T004 [US1] Write test for successful HTTP POST payload formatting and delivery using injected test transport in test/agent_os/connector/discord_notify_test.exs

### Implementation for User Story 1

- [x] T005 [US1] Implement the `execute/2` function for `notify` action in `lib/agent_os/connector/discord_notify.ex`
- [x] T006 [US1] Inject transport via `Application.get_env` in `lib/agent_os/connector/discord_notify.ex`
- [x] T007 [US1] Return `{:error, {:unknown_method, other}}` for unknown actions.

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently

---

## Phase 4: User Story 2 - Loud Failure on Delivery Errors (Priority: P1)

**Goal**: Return explicit errors if the Discord webhook POST fails.

**Independent Test**: Configure the test transport to return 4xx/5xx or timeout, verify the connector bubbles it up.

### Tests for User Story 2 ⚠️

- [x] T008 [US2] Write tests for non-2xx response handling returning `{:error, reason}` in test/agent_os/connector/discord_notify_test.exs
- [x] T009 [US2] Write tests for network timeout returning `{:error, reason}` in test/agent_os/connector/discord_notify_test.exs

### Implementation for User Story 2

- [x] T010 [US2] Add pattern matching for `Req` error responses in `lib/agent_os/connector/discord_notify.ex`
- [x] T011 [US2] Add pattern matching for non-200 status codes to return error tuples in `lib/agent_os/connector/discord_notify.ex`

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [x] T012 Run quickstart.md validation locally to ensure manual smoke testing works.
- [x] T013 Verify world-B verification suite passes.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3+)**: All depend on Foundational phase completion
  - User stories can then proceed in parallel (if staffed)
  - Or sequentially in priority order (P1 → P2 → P3)
- **Polish (Final Phase)**: Depends on all desired user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2)
- **User Story 2 (P1)**: Extends User Story 1 error handling.

### Within Each User Story

- Tests MUST be written and FAIL before implementation
- Core implementation before integration
- Story complete before moving to next priority

### Parallel Opportunities

- Tests and Implementation can run in parallel if divided by user story.

---

## Parallel Example: User Story 1 & 2

```bash
# Launch both tests together:
Task: "Write test for successful HTTP POST payload formatting and delivery"
Task: "Write tests for non-2xx response handling"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Test User Story 1 independently
5. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Test independently → Deploy/Demo (MVP!)
3. Add User Story 2 → Test independently → Deploy/Demo

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Verify tests fail before implementing
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Avoid: vague tasks, same file conflicts, cross-story dependencies that break independence
