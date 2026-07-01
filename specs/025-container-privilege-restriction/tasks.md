# Tasks: Container Privilege Restriction

**Input**: Design documents from `/specs/025-container-privilege-restriction/`  
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Define module constants for resource ceilings in lib/agent_os/sandbox.ex
- [x] T002 Implement CPU parsing helper function in lib/agent_os/sandbox.ex

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core validation helper that must be complete before any user story can be implemented

**⚠️ CRITICAL**: No user story implementation can begin until these verification hooks are designed

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Run Agent Safely without Host Privilege Escalation (Priority: P1) 🎯 MVP

**Goal**: Reject root user execution attempts and drop capabilities/privileges unconditionally.

**Independent Test**: Unit tests in `test/agent_os/sandbox_test.exs` checking that root configurations are rejected and capabilities are dropped.

### Tests for User Story 1
- [x] T003 [P] [US1] Add unit tests for user verification and capability dropping in test/agent_os/sandbox_test.exs

### Implementation for User Story 1
- [x] T004 [US1] Implement user verification logic to reject root in lib/agent_os/sandbox.ex
- [x] T005 [US1] Ensure drop capability and disable privilege escalation flags are unconditional in lib/agent_os/sandbox.ex

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently

---

## Phase 4: User Story 2 - Prevent Resource and Process Exhaustion (Priority: P2)

**Goal**: Enforce memory/cpu ceilings, process limits (fork-bomb protection), and file descriptor limits.

**Independent Test**: Unit tests for limits, and gated docker integration tests checking memory OOM and fork-bomb caps.

### Tests for User Story 2
- [x] T006 [P] [US2] Add unit tests for resource ceilings, pids limit, and ulimit flags in test/agent_os/sandbox_test.exs
- [x] T007 [P] [US2] Add gated integration test for fork bomb process limit checking in test/agent_os/isolation_test.exs

### Implementation for User Story 2
- [x] T008 [US2] Implement memory and CPU allocation ceiling checks in lib/agent_os/sandbox.ex
- [x] T009 [US2] Add pids-limit and file descriptor ulimit flags to container execution arguments in lib/agent_os/sandbox.ex

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently

---

## Phase 5: User Story 3 - Restrict Network and Writable Volumes (Priority: P3)

**Goal**: Reject non-none network settings and non-readonly host bind mounts (except the inference socket).

**Independent Test**: Unit tests checking network rejection and mount-point read-only validation.

### Tests for User Story 3
- [x] T010 [P] [US3] Add unit tests for network restriction and writable mount checks in test/agent_os/sandbox_test.exs

### Implementation for User Story 3
- [x] T011 [US3] Implement network verification to restrict connection interfaces in lib/agent_os/sandbox.ex
- [x] T012 [US3] Implement mount verification to enforce read-only bindings on all filesystems except inference socket in lib/agent_os/sandbox.ex

**Checkpoint**: All user stories should now be independently functional

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Code cleanup, testing validation, and documentation updates.

- [x] T013 Run code formatters and check linter compliance in lib/agent_os/sandbox.ex
- [x] T014 Run full ExUnit test suite to verify all checks pass in test/agent_os/
- [x] T015 [P] Complete walkthrough documentation in specs/025-container-privilege-restriction/walkthrough.md

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **User Stories (Phase 3+)**: All depend on Setup phase completion
- **Polish (Final Phase)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Setup (Phase 1) - No dependencies on other stories
- **User Story 2 (P2)**: Can start after Setup (Phase 1)
- **User Story 3 (P3)**: Can start after Setup (Phase 1)

---

## Parallel Example: User Story 1 & 2

```bash
# Developer A starts User Story 1 unit tests:
Task: "Add unit tests for user verification and capability dropping in test/agent_os/sandbox_test.exs"

# Developer B starts User Story 2 unit tests:
Task: "Add unit tests for resource ceilings, pids limit, and ulimit flags in test/agent_os/sandbox_test.exs"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 3: User Story 1
3. **STOP and VALIDATE**: Test User Story 1 independently
4. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup -> basic framework ready
2. Add User Story 1 -> Test independently -> Deploy/Demo (MVP!)
3. Add User Story 2 -> Test independently -> Deploy/Demo
4. Add User Story 3 -> Test independently -> Deploy/Demo
5. Each story adds value without breaking previous stories
