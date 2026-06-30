# Tasks: Review Modes + Deterministic Envelope Predicate

**Input**: Design documents from `/specs/011-review-modes-envelope/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: ExUnit tests are explicitly requested in the verification plan.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Mount the `"provenance"` StateStore in the application supervision tree in lib/agent_os/application.ex
- [x] T002 [P] Configure the `"provenance"` storage path in config/config.exs

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 [P] Define the `deploy/3` function signature and stub implementation in lib/agent_os/provisioner.ex
- [x] T004 [P] Implement the helper function `envelope_predicate?/2` inside lib/agent_os/provisioner.ex checking read-only, no-egress, and spend bounds
- [x] T005 [P] Implement helper functions for manifest hashing and recording provenance (`record_provenance/3`) in lib/agent_os/provisioner.ex
- [x] T006 Implement deployment history check in `Provisioner.deploy/3` to bypass block on matching manifest hashes

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Always Review Deployments (Priority: P1) 🎯 MVP

**Goal**: Implement default blocking human-review behavior and recording of `reviewed=human` provenance.

**Independent Test**: Deploy an agent under `:always_review` and assert it blocks, creating a pending approval. Approve it via `TriggerGateway` and verify it records `reviewed=human` and triggers execution.

### Implementation for User Story 1

- [x] T007 [US1] Implement `:always_review` blocking logic in `Provisioner.deploy/3` creating a pending approval entry in StateStore "pending_approvals"
- [x] T008 [US1] Add a match for type `"deploy"` in `AgentOS.Effector.act/1` to record approved status and call `AgentOS.RunSupervisor.start_run/1`
- [x] T009 [P] [US1] Write ExUnit tests in test/agent_os/provisioner_test.exs verifying that `deploy/3` blocks and returns a unique ref under `:always_review`
- [x] T010 [P] [US1] Write ExUnit tests in test/agent_os/trigger_gateway_test.exs verifying deploy approval resumption and effector execution

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently.

---

## Phase 4: User Story 2 - Review If Risky Deployments (Priority: P2)

**Goal**: Implement conditional deployment based on the envelope predicate and gate-breach history check.

**Independent Test**: Verify that an in-envelope agent deploys without blocking (`skipped-in-envelope`), while an out-of-envelope or flagged agent blocks on human approval.

### Implementation for User Story 2

- [x] T011 [US2] Implement `:review_if_risky` logic in `Provisioner.deploy/3` evaluating `envelope_predicate?/2` and checking conformance history for `:gate_breach`
- [x] T012 [P] [US2] Write ExUnit tests in test/agent_os/provisioner_test.exs checking that the envelope predicate correctly classifies the discovery agent manifest as out-of-envelope
- [x] T013 [P] [US2] Write ExUnit tests in test/agent_os/provisioner_test.exs checking that a clean in-envelope manifest deploys immediately
- [x] T014 [P] [US2] Write ExUnit tests in test/agent_os/provisioner_test.exs checking that a gate-breach flag in the conformance store blocks the deployment

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently.

---

## Phase 5: User Story 3 - Dangerously Skip Review (Priority: P3)

**Goal**: Implement immediate deploy skip under `--dangerously-skip-review` while ensuring the runtime safety gate remains fully active.

**Independent Test**: Deploy an out-of-envelope manifest under `:dangerously_skip_review` (no block) and attempt to run a mutated action; verify it blocks at runtime.

### Implementation for User Story 3

- [x] T015 [US3] Implement `:dangerously_skip_review` logic in `Provisioner.deploy/3` to proceed instantly and record `dangerously-skipped`
- [x] T016 [US3] Integrate the deploy check at the entry point of `AgentOS.RunWorker.run_once/1` blocking execution if deployment is pending
- [x] T017 [P] [US3] Write integration tests in test/agent_os/world_b_test.exs verifying that the runtime gate is fully active and blocks breaches under `:dangerously_skip_review`

**Checkpoint**: All user stories should now be independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [x] T018 [P] Read deploy provenance and format it as `DEPLOY PROVENANCE: ...` next to capability render in lib/agent_os/inventory.ex
- [x] T019 Write ExUnit tests verifying the inventory displays the correct provenance in test/agent_os/inventory_test.exs
- [x] T020 [P] Run `mix format` and `mix test` to verify linting and test suite pass cleanly across the entire codebase

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately.
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories.
- **User Stories (Phase 3+)**: All depend on Foundational phase completion.
  - User stories can then proceed in parallel (if staffed) or sequentially in priority order (P1 → P2 → P3).
- **Polish (Final Phase)**: Depends on all desired user stories being complete.

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories.
- **User Story 2 (P2)**: Can start after Foundational (Phase 2) - May integrate with US1 but should be independently testable.
- **User Story 3 (P3)**: Can start after Foundational (Phase 2) - May integrate with US1/US2 but should be independently testable.

---

## Parallel Example: User Story 1

```bash
# Launch both test files for User Story 1 implementation in parallel:
Task: "Write ExUnit tests in test/agent_os/provisioner_test.exs verifying that deploy/3 blocks and returns a unique ref under :always_review"
Task: "Write ExUnit tests in test/agent_os/trigger_gateway_test.exs verifying deploy approval resumption and effector execution"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Test User Story 1 independently using `mix test`
5. Deploy/demo if ready

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Test independently → Deploy/Demo (MVP!)
3. Add User Story 2 → Test independently → Deploy/Demo
4. Add User Story 3 → Test independently → Deploy/Demo
5. Each story adds value without breaking previous stories
