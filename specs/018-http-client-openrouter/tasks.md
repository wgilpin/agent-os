# Tasks: HTTP Client & OpenRouter Transport

**Input**: Design documents from `/specs/018-http-client-openrouter/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: Test tasks are included below for validating both the success path and mock-injected HTTP error paths.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- Paths shown assume single project: `lib/`, `test/`, `mix.exs` at repository root.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Add `{:req, "~> 0.5"}` to dependencies in mix.exs
- [x] T002 Retrieve and compile project dependencies via mix command

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 Extend the `@type result` typespec in lib/agent_os/inference_broker.ex to include `:timeout`, `:network_error`, and `{:http_status, integer()}`
- [x] T004 Update error handling in AgentOS.InferenceBroker.complete/2 in lib/agent_os/inference_broker.ex to match and propagate `{:error, reason}` returned by `provider_fn`

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Successful Inference via OpenRouter (Priority: P1) 🎯 MVP

**Goal**: Replace real_provider_fn/3 stub with a real outbound POST request to OpenRouter using Req and the credentials token.

**Independent Test**: Register a mock model and verify that a successful response is parsed and recorded accurately in the spend ledger.

### Implementation for User Story 1

- [x] T005 [US1] Implement real_provider_fn/3 in lib/agent_os/inference_broker.ex to execute Req.post/2 call using dynamic credential token
- [x] T006 [US1] Parse response JSON payload and extract choices content and usage data in real_provider_fn/3 in lib/agent_os/inference_broker.ex

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently

---

## Phase 4: User Story 2 - Robust HTTP Failure Handling (Priority: P1)

**Goal**: Map connection issues, timeouts, and non-200 API statuses to structured broker errors instead of crashing.

**Independent Test**: Assert that mocked request errors map to error tuples.

### Implementation for User Story 2

- [x] T007 [US2] Implement timeout exception catching and return {:error, :timeout} in real_provider_fn/3 in lib/agent_os/inference_broker.ex
- [x] T008 [US2] Implement general network/connection exception catching and return {:error, :network_error} in real_provider_fn/3 in lib/agent_os/inference_broker.ex
- [x] T009 [US2] Check response HTTP status code and return {:error, {:http_status, status}} for non-200 responses in real_provider_fn/3 in lib/agent_os/inference_broker.ex
- [x] T010 [P] [US2] Write unit tests in test/agent_os/inference_broker_test.exs that mock and assert the new HTTP error status, timeout, and network failure mappings

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently

---

## Phase 5: User Story 3 - Test Isolation (Priority: P2)

**Goal**: Confirm that the test suite does not make any daily network connections to the external API.

**Independent Test**: Run the test suite and ensure no real requests are made.

### Implementation for User Story 3

- [x] T011 [US3] Verify that all test cases in test/agent_os/inference_broker_test.exs use provider_fn mocks to prevent live network access

**Checkpoint**: All user stories should now be independently functional

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [x] T012 Run mix format and mix credo over modified Elixir codebase files to ensure style compliance
- [x] T013 Validate the integration setup in iex -S mix per instructions in specs/018-http-client-openrouter/quickstart.md

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately.
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories.
- **User Stories (Phase 3+)**: All depend on Foundational phase completion.
- **Polish (Final Phase)**: Depends on all desired user stories being complete.

### Parallel Opportunities

- All test writing and specific error path mocking can proceed in parallel once the base implementation structure is outlined.
- Code style formatting and local console validation can be executed concurrently.
