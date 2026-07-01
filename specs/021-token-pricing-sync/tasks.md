# Tasks: Token Pricing Sync

**Input**: Design documents from `/specs/021-token-pricing-sync/`
**Prerequisites**: [plan.md](file:///Users/will/projects/agent_os/specs/021-token-pricing-sync/plan.md) (required), [spec.md](file:///Users/will/projects/agent_os/specs/021-token-pricing-sync/spec.md) (required for user stories), [research.md](file:///Users/will/projects/agent_os/specs/021-token-pricing-sync/research.md), [data-model.md](file:///Users/will/projects/agent_os/specs/021-token-pricing-sync/data-model.md), [contracts/openrouter-models-api.md](file:///Users/will/projects/agent_os/specs/021-token-pricing-sync/contracts/openrouter-models-api.md)

**Tests**: Test tasks are included as requested by the test-driven backend requirements of the AgentOS Constitution.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Update configuration files to support the new micro-dollars per million tokens (pico-dollars per token) scale.

- [x] T001 Update default fallback configurations in `config/config.exs` to the micro-dollars per million tokens scale
- [x] T002 Update test environment fallback configurations in `config/config.exs` to the scaled rates

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core logic and pricing math adjustments to use the new high-precision integer scale.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T003 Modify typespecs and calculations in `lib/agent_os/inference_price.ex` to implement the new micro-dollars per million tokens precision scale
- [x] T004 Update the complete/2 logic in `lib/agent_os/inference_broker.ex` to interface correctly with the new pricing scale
- [x] T005 Update existing tests in `test/agent_os/inference_broker_test.exs` to reflect the updated mock pricing values and scale

**Checkpoint**: Foundation ready - user story implementation can now begin.

---

## Phase 3: User Story 1 - Dynamic Model Pricing Sync (Priority: P1) 🎯 MVP

**Goal**: Automatically fetch and load pricing from OpenRouter at boot and periodically, updating the active pricing cache.

**Independent Test**: Verify that model prices are populated dynamically at boot from mock OpenRouter responses, overriding config fallback values.

### Tests for User Story 1
- [x] T006 [P] [US1] Write test cases in `test/agent_os/inference_price_sync_test.exs` verifying happy path sync, decimal parsing scaling, and periodic timers

### Implementation for User Story 1
- [x] T007 [P] [US1] Implement string parsing helpers in `lib/agent_os/inference_price_sync.ex` to parse OpenRouter's decimal USD-per-token strings to integer micro-dollars per million tokens
- [x] T008 [P] [US1] Implement fetch and merge logic in `lib/agent_os/inference_price_sync.ex` using `Req` to retrieve models and update the cache in application env
- [x] T009 [US1] Add `AgentOS.InferencePriceSync` GenServer to the supervisor tree in `lib/agent_os/application.ex` to start the dynamic sync at boot
- [x] T010 [US1] Set up the periodic scheduling refresh timer in `lib/agent_os/inference_price_sync.ex` to run a refresh every 24 hours

**Checkpoint**: At this point, User Story 1 is fully functional and testable independently.

---

## Phase 4: User Story 2 - Sub-Micro-Dollar Precision Metering (Priority: P1)

**Goal**: Meter very cheap models with exact-integer precision without rounding to zero or under-charging.

**Independent Test**: Run a simulated 1-token call on a $0.15/1M model and check that the spend ledger is updated by exactly 1 micro-dollar (rounded up).

### Tests for User Story 2
- [x] T011 [P] [US2] Write tests in `test/agent_os/inference_broker_test.exs` to assert that calls to cheap models calculate correct micro-dollars and do not round to zero

### Implementation for User Story 2
- [x] T012 [US2] Update `micro_dollars/2` in `lib/agent_os/inference_price.ex` to round up non-zero pico-dollar costs to the nearest micro-dollar

**Checkpoint**: At this point, User Stories 1 and 2 work independently.

---

## Phase 5: User Story 3 - Fail-Closed Fallback (Priority: P2)

**Goal**: Fall back to safe offline prices if the dynamic sync is unreachable, preventing unpriced models from being called.

**Independent Test**: Verify that if the API is offline at boot, fallback prices are retained, warnings are logged, and unknown models return `{:error, :unpriced_model}`.

### Tests for User Story 3
- [x] T013 [P] [US3] Write tests in `test/agent_os/inference_price_sync_test.exs` covering fail-closed and offline fallback behavior when the endpoint returns error statuses or network is unreachable

### Implementation for User Story 3
- [x] T014 [US3] Implement network fail-closed and fallback handling in `lib/agent_os/inference_price_sync.ex` to log warning messages and preserve configuration fallbacks on failure

**Checkpoint**: All user stories are independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Formatting, documentation, and system-wide checks.

- [x] T015 [P] Update specifications, plans, and README files to reflect final implementation details if needed
- [x] T016 Run formatting and quality checks (`mix format` and `mix credo`) and execute all automated tests

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3+)**: All depend on Foundational phase completion
  - User Story 1 (P1) must complete to verify dynamic sync.
  - User Story 2 (P1) can proceed in parallel or after User Story 1.
  - User Story 3 (P2) builds on the sync error handling and depends on User Story 1 structure.
- **Polish (Final Phase)**: Depends on all desired user stories being complete.

### Parallel Opportunities

- Setup tasks `T001` and `T002` can run in parallel.
- Synced tests `T006` and helpers `T007`, `T008` can run in parallel.
- Polish task `T015` can run in parallel with general code cleanups.

---

## Parallel Example: User Story 1

```bash
# Implement the decimal parser and JSON fetcher in parallel:
Task: "Implement string parsing helpers in lib/agent_os/inference_price_sync.ex"
Task: "Implement fetch and merge logic in lib/agent_os/inference_price_sync.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 & 2 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1
4. Complete Phase 4: User Story 2
5. **STOP and VALIDATE**: Test User Story 1 and 2 independently
6. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Test dynamically fetched pricing (MVP!)
3. Add User Story 2 → Test precise sub-micro-dollar calculation
4. Add User Story 3 → Test network down fallback handling
5. Each story adds value without breaking previous stories
