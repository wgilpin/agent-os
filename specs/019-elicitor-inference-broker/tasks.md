# Tasks: Route Elicitor through Inference Broker

**Input**: Design documents from `/specs/019-elicitor-inference-broker/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, quickstart.md

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Configure price entry for `"google/gemini-2.5-flash"` in `config/config.exs`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core substrate changes needed before Python agent modification

- [x] T002 Update `lib/agent_os/inference_broker.ex` to check `Application.get_env(:agent_os, :provider_fn)` in `complete/2` as a test seam override

---

## Phase 3: User Story 1 - Centralized Inference Elicitation (Priority: P1) 🎯 MVP

**Goal**: Route elicitation inference calls through the substrate UDS proxy

**Independent Test**: Running the elicitor live routes requests through `$INFERENCE_SOCKET` to `InferenceBroker`

### Implementation for User Story 1

- [x] T003 [P] [US1] Remove urllib, OpenRouter direct URL, and `MODEL_KEY` usage from `agents/elicitor/main.py`
- [x] T004 [P] [US1] Implement UDS client transport connection to `$INFERENCE_SOCKET` in `agents/elicitor/main.py` and parse the completion from the returned JSON
- [x] T005 [US1] Update `lib/agent_os/elicitation_session.ex` to generate a dynamic token, register it under the `"elicitor"` identity in `init/1`, unregister it on shutdown/termination, and pass the token and socket via environment variables to the python port

---

## Phase 4: User Story 2 - Metering and Spend Cap Enforcement (Priority: P1)

**Goal**: Meter elicitation spend in the spend ledger and block requests exceeding the cap

**Independent Test**: Elicitor calls increase spend in `spend_ledger`, and exceeding the cap throws a breach error

### Implementation for User Story 2

- [x] T006 [US2] Add unit tests in `test/agent_os/elicitation_test.exs` using the mock provider function to verify that elicitation spend is metered under `"elicitor"` and cap breach is properly enforced

---

## Phase 5: User Story 3 - Offline Mock Elicitation (Priority: P1)

**Goal**: Keep mock mode deterministic and offline

**Independent Test**: Mock mode doesn't open sockets or make network requests

### Implementation for User Story 3

- [x] T007 [P] [US3] Ensure mock mode in `agents/elicitor/main.py` executes offline without checking `$INFERENCE_SOCKET`
- [x] T008 [P] [US3] Run python tests using `uv run pytest agents/elicitor/test_main.py` and ensure they pass

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final system tests and validation

- [x] T009 Run the full ExUnit test suite via `mix test` and verify that all tests pass
- [x] T010 Manually verify elicitor interactive flow via `mix agent_os.elicit "reply to recruiter emails"`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Phase 1.
- **User Story 1 (Phase 3)**: Depends on Phase 2.
- **User Story 2 (Phase 4)**: Depends on Phase 3.
- **User Story 3 (Phase 5)**: Depends on Phase 3.
- **Polish (Phase 6)**: Depends on all other phases.

### Parallel Opportunities

- T003 and T004 can be implemented in parallel.
- US2 and US3 implementation/tests can be worked on in parallel.

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Setup prices config.
2. Update the InferenceBroker test override.
3. Update elicitation session to register token.
4. Implement UDS connection in Python agent.
5. Verify live routing locally.
