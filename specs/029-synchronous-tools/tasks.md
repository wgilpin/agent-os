# Tasks: Synchronous Tools + Web Search

**Input**: Design documents from `/specs/029-synchronous-tools/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- Paths assume single project at repository root (`lib/agent_os/`, `test/agent_os/`)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [ ] T001 Verify project compiles and format is correct on the current branch `029-synchronous-tools`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [ ] T002 Add `execute_tool/2` behaviour callback and add it to `@optional_callbacks` in `lib/agent_os/connector.ex`
- [ ] T003 [P] Extend `capability` type spec in `lib/agent_os/connector.ex` to support `tool_declaration` field

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Gated synchronous tool use (Priority: P1) 🎯 MVP

**Goal**: Synchronous tool-use loop execution mid-reasoning.

**Independent Test**: Configure an agent with a manifest granting `web_search` and verify it runs.

### Implementation for User Story 1

- [ ] T004 Implement recursive `tool_loop` inside `complete/2` in `lib/agent_os/inference_broker.ex`
- [ ] T005 [P] Update `real_provider_fn` to format and send `tools` payload when calling OpenRouter in `lib/agent_os/inference_broker.ex`
- [ ] T006 Update response parser `parse_openrouter_response` to preserve choice message metadata (including `tool_calls`) in `lib/agent_os/inference_broker.ex`

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently

---

## Phase 4: User Story 2 - Access Control & Sandboxing (Priority: P2)

**Goal**: Enforce tool gates; block and hide tools from agents without grants.

**Independent Test**: Run agent without the grant and verify tool schemas are not present and attempts are refused.

### Implementation for User Story 2

- [ ] T007 Implement active tool filtering and tool schema builder based on agent manifest grants in `lib/agent_os/inference_broker.ex`
- [ ] T008 Implement authorization checks inside tool processing loop to refuse ungranted tool calls in `lib/agent_os/inference_broker.ex`

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently

---

## Phase 5: User Story 3 - Metering and Spend Control (Priority: P3)

**Goal**: Track tool call costs and trigger kill-on-breach.

**Independent Test**: Run agent with tight spend cap and verify it is terminated on tool call.

### Implementation for User Story 3

- [ ] T009 Implement spend ledger lookup and spend cap breach check prior to tool call execution in `lib/agent_os/inference_broker.ex`
- [ ] T010 Update the spend ledger with completed tool costs in `lib/agent_os/inference_broker.ex`

**Checkpoint**: Spend control is fully integrated.

---

## Phase 6: User Story 4 - Fault Containment & Timeouts (Priority: P4)

**Goal**: Isolate tool execution (timeout and crash capture).

**Independent Test**: Invoke a tool that hangs or crashes and verify it is caught gracefully.

### Implementation for User Story 4

- [ ] T011 Implement `execute_tool_isolated` with Task.Supervisor, timeboxing (5s), and try-rescue/catch wrappers in `lib/agent_os/inference_broker.ex`

**Checkpoint**: Tool execution is isolated and fault-tolerant.

---

## Phase 7: Web Search Connector (Priority: P5)

**Goal**: Land the `web_search` connector.

**Independent Test**: Run web search connector with and without mock functions.

### Implementation for Phase 7

- [ ] T012 [P] Implement the `AgentOS.Connector.WebSearch` behaviour module in `lib/agent_os/connector/web_search.ex`
- [ ] T013 [P] Add environment configuration and mock support for `web_search` in `config/config.exs` or `config/test.exs`

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Verification and final code formatting

- [ ] T014 Add unit tests for tool schema ads, execution, metering, and error recovery in `test/agent_os/inference_broker_test.exs`
- [ ] T015 Run `mix format` and `mix test` to ensure all tests pass and are clean

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3+)**: All depend on Foundational phase completion
- **Polish (Final Phase)**: Depends on all desired user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2)
- **User Story 2 (P2)**: Can start after Foundational (Phase 2)
- **User Story 3 (P3)**: Can start after US1 is functional
- **User Story 4 (P4)**: Can start after US1 is functional
- **Phase 7 (P5)**: Depends on Phase 2 completion

---

## Parallel Opportunities

- All tasks marked [P] can run in parallel.
- Phase 7 (Web search connector implementation) can run in parallel with User Story implementation.

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Test User Story 1 independently using mocked provider
5. Proceed to other stories
