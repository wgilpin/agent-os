# Tasks: Stage 1 Elicit Spec

**Input**: Design documents from `/specs/012-elicit-spec/`
**Prerequisites**: plan.md (required), spec.md (required)

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Create initial empty files at lib/agent_os/elicitation.ex and agents/elicitor/models.py
- [x] T002 Configure uv dependencies for elicitor in pyproject.toml

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core data models and typespecs that must be complete before any user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 [P] Implement typespecs and struct definitions in lib/agent_os/elicitation.ex
- [x] T004 [P] Implement Pydantic schemas in agents/elicitor/models.py

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Prompting purpose and clarifying intent (Priority: P1) 🎯 MVP

**Goal**: Establish the interactive prompt-response loop driving spec elicitation questions using Gemini.

**Independent Test**: Start session with `mix agent_os.elicit "reply to recruiter emails"`, answer 2-3 mock questions, and get a structured output draft.

### Tests for User Story 1

- [x] T005 [P] [US1] Implement mock Gemini API client in agents/elicitor/test_main.py
- [x] T006 [P] [US1] Write ExUnit tests for session lifecycle in test/agent_os/elicitation_test.exs

### Implementation for User Story 1

- [x] T007 [P] [US1] Implement Gemini API elicitation prompting in agents/elicitor/main.py
- [x] T008 [US1] Implement session state and port manager in lib/agent_os/elicitation_session.ex
- [x] T009 [US1] Implement the Mix task CLI entry point in lib/mix/tasks/agent_os.elicit.ex

**Checkpoint**: User Story 1 is fully functional and testable independently.

---

## Phase 4: User Story 2 - Pushing back on excess capabilities / KISS enforcement (Priority: P2)

**Goal**: Parse requested capabilities, check them against KISS rules, and warn user of scope creep.

**Independent Test**: Run elicitation with a request containing extra permissions (e.g. "delete messages") and see the warning.

### Implementation for User Story 2

- [x] T010 [P] [US2] Update agents/elicitor/main.py to detect excess capabilities and check KISS rules
- [x] T011 [US2] Update lib/mix/tasks/agent_os.elicit.ex to render scope creep warnings

**Checkpoint**: User Story 2 can be tested independently.

---

## Phase 5: User Story 3 - Structured Spec Confirmation (Priority: P1)

**Goal**: Present the final capability list and block for human confirmation before writing the final spec file.

**Independent Test**: CLI renders the spec, waits for 'yes' or 'no', and outputs the confirmed `elicited_spec.json`.

### Implementation for User Story 3

- [x] T012 [US3] Integrate capability renderer in lib/mix/tasks/agent_os.elicit.ex using AgentOS.CapabilityRender
- [x] T013 [US3] Update lib/agent_os/elicitation_session.ex to write elicited_spec.json on confirmation

**Checkpoint**: All user stories are independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Formatting, cleanup, and validation

- [x] T014 [P] Run code formatting with ruff format agents/elicitor/ and mix format
- [x] T015 Verify quickstart.md validation manually

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3+)**: All depend on Foundational phase completion
  - User Story 1 (P1) is MVP and should be completed first
  - User Story 2 (P2) and User Story 3 (P1) can then proceed

### Parallel Opportunities

- T003 and T004 in Foundational phase can run in parallel
- T005 and T006 (Tests) can run in parallel with T007 (Implementation) under User Story 1

---

## Parallel Example: User Story 1

```bash
# Implement mock tests and Gemini prompt in parallel:
Task: "Implement mock Gemini API client in agents/elicitor/test_main.py"
Task: "Implement Gemini API elicitation prompting in agents/elicitor/main.py"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Verify mock elicitation conversation works
