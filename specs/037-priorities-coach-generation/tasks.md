---

description: "Task list for Priorities Coach E2E Generation"
---

# Tasks: Priorities Coach E2E Generation

**Input**: Design documents from `/specs/037-priorities-coach-generation/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, quickstart.md

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [ ] T001 Verify completion and merging of prior dependencies (10-01, 10-02, 10-03)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [ ] T002 Inspect `lib/agent_os/pipeline/` (orchestrator/projection) to verify it can emit path-grants and composite triggers
- [ ] T003 Update manifest projection logic in `lib/agent_os/` to support path grants and composite triggers (if T002 identifies a gap)

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel

---

## Phase 3: User Story 1 - Pipeline Orchestration (Priority: P1) 🎯 MVP

**Goal**: Operator wants the orchestrator to process the Priorities Coach purpose into a machine-written manifest, judge, and agent body.

**Independent Test**: Can be tested by running the generation pipeline on the coach's purpose prompt, verifying that the generated manifest includes the expected grants and triggers, and that it successfully deploys.

### Implementation for User Story 1

- [x] T004 [US1] Feed Priorities Coach purpose into the pipeline orchestrator in `lib/agent_os/pipeline/orchestrator.ex`
- [x] T005 [US1] Verify the generated manifest contains `file_read`/`file_write` (path grant) and `discord_notify` (static credential)
- [x] T006 [US1] Verify the generated manifest contains `%{type: :message}` + time triggers and a spend cap
- [x] T007 [US1] Verify the agent auto-deploys via security review

**Checkpoint**: At this point, User Story 1 should be fully functional and testable independently

---

## Phase 4: User Story 2 - World-B Consistency Validation (Priority: P1)

**Goal**: Security engineer wants the world-B test battery to pass against the generated coach's manifest.

**Independent Test**: Can be tested by running the `world_b_generated_test.exs` suite against the coach's generated manifest.

### Implementation for User Story 2

- [x] T008 [US2] Update `test/agent_os/world_b_generated_test.exs` to load the generated Priorities Coach manifest
- [x] T009 [US2] Execute `mix test test/agent_os/world_b_generated_test.exs`
- [x] T010 [US2] Resolve any unexpected BC-* failures related to the new grant shapes

**Checkpoint**: At this point, User Stories 1 AND 2 should both work independently

---

## Phase 5: User Story 3 - Live Smoke Execution (Priority: P2)

**Goal**: User wants the deployed Priorities Coach to successfully execute its full daily loop.

**Independent Test**: Can be fully tested manually by waiting for the 0800 time trigger or invoking it, and observing the real Discord channel and local file.

### Implementation for User Story 3

- [x] T011 [US3] Execute the manual live smoke testing steps listed in `specs/037-priorities-coach-generation/quickstart.md`
- [x] T012 [US3] Document the successful end-to-end loop in a walkthrough summary or run log

**Checkpoint**: All user stories should now be independently functional

---

## Phase N: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [x] T013 Update `AGENTS.md` and phase documentation
- [x] T014 Code cleanup and refactoring in projection logic if any was added

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3+)**: All depend on Foundational phase completion
- **Polish (Final Phase)**: Depends on all desired user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - No dependencies on other stories
- **User Story 2 (P1)**: Can start after Foundational (Phase 2) - Technically depends on US1 to produce the manifest to test against
- **User Story 3 (P2)**: Depends on US1 completion and successful deployment of the agent

### Within Each User Story

- Core implementation before integration
- Story complete before moving to next priority

### Parallel Opportunities

- Foundational task gap-analysis can happen in parallel with configuring the prompt
- Polish tasks can happen after all stories

---

## Parallel Example: User Story 1

```bash
# Verify the generated outputs
Task: "Verify the generated manifest contains file_read/file_write"
Task: "Verify the generated manifest contains message + time triggers"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL - blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Test User Story 1 independently

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add User Story 1 → Pipeline runs and generates manifest
3. Add User Story 2 → Security rules validated on the new manifest
4. Add User Story 3 → Full live smoke test executes end-to-end

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story should be independently completable and testable
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Avoid: vague tasks, same file conflicts, cross-story dependencies that break independence
