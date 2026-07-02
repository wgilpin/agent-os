# Tasks: Socket Security & Permissions

**Input**: Design documents from `/specs/026-socket-security-permissions/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md

**Tests**: Tests are requested and follow Principle III (Test-Driven Backend) of the Agent OS Constitution.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Includes exact file paths in descriptions.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Verify project structure and configuration readiness for dynamic GID lookup

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core GID resolution logic that acts as the prerequisite for user story implementation

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T002 Implement helper `get_configured_gid/0` in `lib/agent_os/inference_broker.ex` to retrieve target GID from config/env/user fallback
- [x] T003 [P] Add unit tests for GID resolution helper function in `test/agent_os/inference_broker_test.exs`

**Checkpoint**: GID resolution helper complete and verified.

---

## Phase 3: User Story 1 - Secure Host Socket Layer (Priority: P1)

**Goal**: Secure the socket at `data/inference.sock` with `0660` permission and group GID.

**Independent Test**: Assert socket file mode is `0660` and GID matches target GID.

### Tests for User Story 1
> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T004 [US1] Write unit test verifying socket file permission mode `0660` and GID ownership in `test/agent_os/inference_broker_test.exs`

### Implementation for User Story 1

- [x] T005 [US1] Update `start_uds_listener/1` in `lib/agent_os/inference_broker.ex` to apply `File.chmod/2` and `:file.change_group/2` on the socket file

**Checkpoint**: Socket file permissions and group ownership are secured.

---

## Phase 4: User Story 2 - GID-Aligned Agent Inference (Priority: P1)

**Goal**: Align container GID with inference GID during sandbox startup.

**Independent Test**: Assert Docker run arguments include `--user 1000:<inference-gid>`.

### Tests for User Story 2
> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T006 [P] [US2] Write unit test verifying Sandbox `build_argv` user is aligned with configured inference GID in `test/agent_os/sandbox_test.exs`

### Implementation for User Story 2

- [x] T007 [US2] Update container GID alignment mapping during sandbox launch options in `lib/agent_os/run_worker.ex`

**Checkpoint**: Containers are launched with aligned GIDs to allow socket connection.

---

## Phase 5: User Story 3 - Restricted Parent Directory Access (Priority: P2)

**Goal**: Restrict parent directory `data/` to `0700` permissions.

**Independent Test**: Verify `data/` has `0700` permissions.

### Tests for User Story 3
> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T008 [US3] Write unit test for directory `0700` restriction in `test/agent_os/inference_broker_test.exs`

### Implementation for User Story 3

- [x] T009 [US3] Update `start_uds_listener/1` in `lib/agent_os/inference_broker.ex` to enforce `File.chmod/2` on parent directory

**Checkpoint**: Socket parent directory permissions are secured.

---

## Phase 6: User Story 4 - Minimized Mount Surface (Priority: P2)

**Goal**: Only mount `data/inference.sock` file as mount, no parent or other paths writable.

**Independent Test**: Verify mount list contains only socket and all other mounts are read-only.

### Tests for User Story 4
> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T010 [P] [US4] Write unit test verifying container mount path validation in `test/agent_os/sandbox_test.exs`

### Implementation for User Story 4

- [x] T011 [US4] Update Sandbox mount validation in `lib/agent_os/sandbox.ex` if needed to ensure only UDS is writable

**Checkpoint**: Mount surface is minimized.

---

## Phase 7: User Story 5 - Fail-Secure Socket Lifecycle (Priority: P1)

**Goal**: Fail loudly (crash GenServer) if any socket/directory permissions or ownership setup fails.

**Independent Test**: Verify `InferenceBroker` returns `{:stop, ...}` / crashes when permissions fail to apply.

### Tests for User Story 5
> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T012 [US5] Write test mocking permission failures and asserting `InferenceBroker` crashes during `init/1` in `test/agent_os/inference_broker_test.exs`

### Implementation for User Story 5

- [x] T013 [US5] Modify `init/1` and `start_uds_listener/1` in `lib/agent_os/inference_broker.ex` to fail loudly and stop the GenServer if chmod/chown operations fail

**Checkpoint**: Broker startup fails secure.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [x] T014 Run formatting and styling checks (`mix format --check-formatted`) on Elixir codebase
- [x] T015 Run full test suites, including docker-gated live container integration tests (`mix test`)
- [x] T016 Validate the setup using `quickstart.md` steps and document results

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3+)**: All depend on Foundational phase completion
  - Phase 3 (US1), Phase 5 (US3), and Phase 7 (US5) modify `inference_broker.ex` / `inference_broker_test.exs`
  - Phase 4 (US2) and Phase 6 (US4) modify sandbox / docker args execution
  - Phase 8 (Polish) depends on all user stories being complete

### Parallel Opportunities

- T003 (foundational test) and T006 (US2 test) can run in parallel
- T010 (US4 test) can run in parallel with other tests
- Once Phase 2 (Foundational) completes, development can fork:
  - Stream A (Broker Security): US1 (T004-T005), US3 (T008-T009), US5 (T012-T013)
  - Stream B (Sandbox/Mount minimization): US2 (T006-T007), US4 (T010-T011)

---

## Parallel Example: User Story 2 & 4

```bash
# Launch tests for sandbox/mount parameters in parallel
Task: "Write unit test verifying Sandbox build_argv user is aligned with configured inference GID in test/agent_os/sandbox_test.exs"
Task: "Write unit test verifying container mount path validation in test/agent_os/sandbox_test.exs"
```

---

## Implementation Strategy

### MVP First (User Story 1 & 2 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (GID resolution helper)
3. Complete Phase 3: User Story 1 (Socket layer protection)
4. Complete Phase 4: User Story 2 (GID-aligned agent launch)
5. **STOP and VALIDATE**: Test agent execution via the hardened socket connection
6. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 & 2 → Test locally/macOS -> Hardened UDS access works
3. Add User Story 3 → Secure data/ directory permissions
4. Add User Story 4 → Minimize mount limits
5. Add User Story 5 → Fail-secure crash loop on permission failure
6. Complete Polish → Format & styling checks complete
