---

description: "Task list template for feature implementation"
---

# Tasks: Discord Gateway Ingress

**Input**: Design documents from `/specs/036-discord-ingress/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: The examples below include test tasks. Tests are OPTIONAL - only include them if explicitly requested in the feature specification.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Single project**: `src/`, `tests/` at repository root
- **Web app**: `backend/src/`, `frontend/src/`
- **Mobile**: `api/src/`, `ios/src/` or `android/src/`
- Paths shown below assume single project - adjust based on plan.md structure

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Add `websockex` to `mix.exs` dependencies
- [x] T002 Fetch dependencies (`mix deps.get`)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 Scaffold `AgentOS.DiscordGateway` using `WebSockex` in `lib/agent_os/discord_gateway.ex`
- [x] T004 Add `AgentOS.DiscordGateway` to the application supervision tree in `lib/agent_os/application.ex`

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Receive and Route Valid Messages (Priority: P1) 🎯 MVP

**Goal**: Inbound Discord channel messages from the configured user automatically feed into the waiting agent's message trigger.

**Independent Test**: Can be fully tested by providing a stubbed/mocked websocket connection that injects a message payload from the configured user, verifying it is routed to the trigger gateway.

### Tests for User Story 1 (OPTIONAL - only if tests requested) ⚠️

> **NOTE: Write these tests FIRST, ensure they FAIL before implementation**

- [x] T005 [P] [US1] Create unit tests for parsing and dispatching a valid `MESSAGE_CREATE` event in `test/agent_os/discord_gateway_test.exs`

### Implementation for User Story 1

- [x] T006 [US1] Implement Identify payload and connection lifecycle in `lib/agent_os/discord_gateway.ex` using `CredentialSource` for the bot token.
- [x] T007 [US1] Implement parsing logic for the `MESSAGE_CREATE` payload in `lib/agent_os/discord_gateway.ex`.
- [x] T008 [US1] Route matching messages to `AgentOS.TriggerGateway.submit({:message, target_agent, content})` in `lib/agent_os/discord_gateway.ex`.

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently

---

## Phase 4: User Story 2 - Ignore Unauthorized Messages (Priority: P2)

**Goal**: Messages from any other user or channel are ignored, so that unauthorized users cannot inject signals into the substrate or trigger agents.

**Independent Test**: Can be tested by injecting a mocked websocket message with a non-matching user ID or channel ID and asserting that it is dropped.

### Tests for User Story 2 (OPTIONAL - only if tests requested) ⚠️

- [x] T009 [P] [US2] Add unit tests for ignoring mismatched `user_id` in `test/agent_os/discord_gateway_test.exs`
- [x] T010 [P] [US2] Add unit tests for ignoring mismatched `channel_id` in `test/agent_os/discord_gateway_test.exs`

### Implementation for User Story 2

- [x] T011 [US2] Implement filter guards in `lib/agent_os/discord_gateway.ex` to drop mismatched `author.id` and log loudly.
- [x] T012 [US2] Implement filter guards in `lib/agent_os/discord_gateway.ex` to drop mismatched `channel_id` and log loudly.

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [x] T013 Verify supervised reconnection with backoff behaves cleanly on simulated disconnect.
- [x] T014 Run formatting (`mix format`) and linter (`mix credo`).

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

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 2 (P2)**: Can start after Foundational (Phase 2) - May integrate with US1 but should be independently testable

### Within Each User Story

- Tests (if included) MUST be written and FAIL before implementation
- Models before services
- Services before endpoints
- Core implementation before integration
- Story complete before moving to next priority

### Parallel Opportunities

- All Setup tasks marked [P] can run in parallel
- All Foundational tasks marked [P] can run in parallel (within Phase 2)
- Once Foundational phase completes, all user stories can start in parallel (if team capacity allows)
- All tests for a user story marked [P] can run in parallel

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
4. Each story adds value without breaking previous stories
