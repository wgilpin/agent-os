# Tasks: Interactive Elicitation UI

**Input**: Design documents from `/specs/022-elicitation-ui/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Add Phoenix/LiveView dependencies to `mix.exs`
- [x] T002 Configure endpoint, routing, and signing salt in `config/config.exs` and `config/test.exs` (disable server in test env)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 Create base web endpoint module in `lib/agent_os_web/endpoint.ex`
- [x] T004 Create router module mapping paths in `lib/agent_os_web/router.ex`
- [x] T005 [P] Create layout modules in `lib/agent_os_web/layouts.ex` and error HTML view in `lib/agent_os_web/error_html.ex`
- [x] T006 Create root and app templates in `lib/agent_os_web/layouts/root.html.heex` and `lib/agent_os_web/layouts/app.html.heex`
- [x] T007 Mount PubSub and Endpoint in the supervision tree in `lib/agent_os/application.ex`
- [x] T008 [P] Create styles in `priv/static/app.css` and client JS in `priv/static/app.js`

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Landing & Session Initiation (Priority: P1) 🎯 MVP

**Goal**: Allow users to land, input initial purpose, and start elicitation session.

**Independent Test**: Visit root page, fill input, submit, and see elicitor's first question.

### Implementation for User Story 1

- [x] T009 [US1] Create LiveView file `lib/agent_os_web/live/elicitation_live.ex` with mounting and landing state render
- [x] T010 [US1] Add form submission handler to start `ElicitationSession` GenServer in `lib/agent_os_web/live/elicitation_live.ex`

**Checkpoint**: User Story 1 is functional. Elicitation session starts correctly.

---

## Phase 4: User Story 2 - Elicitation Turn Loop & Live Spec (Priority: P1)

**Goal**: Chat interaction turn loop with real-time specification updates in the sidebar.

**Independent Test**: Enter responses to elicitor questions, check they append to scrollable chat, and check that sidebar fields fill in.

### Implementation for User Story 2

- [x] T011 [US2] Implement user message submit form and event handler in `lib/agent_os_web/live/elicitation_live.ex`
- [x] T012 [US2] Implement transcript display and dynamic Live Spec rendering in `lib/agent_os_web/live/elicitation_live.ex`

**Checkpoint**: Elicitation conversation loop works and sidebar spec updates dynamically.

---

## Phase 5: User Story 3 - KISS Scope Creep Warning (Priority: P2)

**Goal**: Show a non-blocking KISS check warning banner if scope creep is detected.

**Independent Test**: Reply with complex scope requests and assert warning banner displays correct pushback.

### Implementation for User Story 3

- [x] T013 [US3] Add scope creep detection check and warning banner render in `lib/agent_os_web/live/elicitation_live.ex`

**Checkpoint**: Scope creep warnings appear without disrupting input flow.

---

## Phase 6: User Story 4 - Spec Confirmation & Persistence (Priority: P1)

**Goal**: Prompt user to confirm spec, write it to file, and cleanly stop GenServer on exit.

**Independent Test**: Confirm spec, check file exists on disk, and check that GenServer process is terminated.

### Implementation for User Story 4

- [x] T014 [US4] Implement confirmation/refine prompt rendering and confirmation handling in `lib/agent_os_web/live/elicitation_live.ex`
- [x] T015 [US4] Implement LiveView `terminate/2` callback for clean GenServer shutdown in `lib/agent_os_web/live/elicitation_live.ex`

**Checkpoint**: Spec confirmation, writing, and cleanup works cleanly.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Verification, tests, and formatting

- [x] T016 [P] Write integration tests in `test/agent_os_web/elicitation_live_test.exs`
- [x] T017 Run `mix format` and `mix test` to verify linting and test suites pass
- [x] T018 Run manual validation checks per `specs/022-elicitation-ui/quickstart.md`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: Can start immediately.
- **Foundational (Phase 2)**: Depends on Setup (Phase 1).
- **User Stories (Phases 3+)**: Depend on Foundational (Phase 2).
- **Polish (Phase 7)**: Depends on all user stories being complete.

### Within Each User Story

- UI and event handlers are implemented in the same module.
- Story must be fully functional and testable before moving to next.

### Parallel Opportunities

- Setup tasks and foundational layout/asset tasks marked [P] can run in parallel.
- Integration tests can be written in parallel during implementation.

---

## Parallel Example: Setup & Foundation

```bash
# Setup CSS styling and base layouts in parallel
Task: "Create styles in priv/static/app.css and client JS in priv/static/app.js"
Task: "Create layout modules in lib/agent_os_web/layouts.ex and error HTML view in lib/agent_os_web/error_html.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 & 2)

1. Setup routing, endpoint, and layouts.
2. Complete landing page and start GenServer.
3. Complete chat interaction turn loop and live spec sidebar.
4. Verify end-to-end basic elicitation.

### Incremental Delivery

1. Setup + Foundation.
2. User Story 1 (Landing).
3. User Story 2 (Turn Loop + Spec).
4. User Story 3 (Creep Warning).
5. User Story 4 (Confirm/Write).
6. Polish & Tests.
