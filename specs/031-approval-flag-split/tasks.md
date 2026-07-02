# Tasks: Approval Flag Split

**Input**: Design documents from `/specs/031-approval-flag-split/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- Paths assume single project at repository root (`lib/agent_os/`, `test/agent_os/`)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic verification

- [ ] T001 Verify project compiles and format is correct on the current branch `031-approval-flag-split`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core connector metadata schema update

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [ ] T002 Update the capability type spec and metadata format in `lib/agent_os/connector.ex`
- [ ] T003 [P] Update metadata declarations in all four connectors under `lib/agent_os/connector/` (replacing `requires_approval?` with the split flags)

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 & 2 - Gate Parking (Priority: P1) 🎯 MVP

**Goal**: The Gate parks proposed actions strictly based on the new `requires_runtime_approval?` flag.

**Independent Test**: Verify that a connector with runtime approval set to true blocks, while one set to false executes without parking.

### Implementation for User Story 1 & 2

- [ ] T004 Refactor Gate checks to check `requires_runtime_approval?` for parking proposed actions in `lib/agent_os/gate.ex`

**Checkpoint**: Gate parking MVP complete.

---

## Phase 4: User Story 3 - Provisioner Deploy Consent (Priority: P2)

**Goal**: Enforce `requires_deploy_consent?` inside `deploy` safety checks.

**Independent Test**: Manifests containing a connector with deploy consent set to true fail `envelope_predicate?/2` and require human deploy review.

### Implementation for User Story 3

- [ ] T005 Update `envelope_predicate?/2` to inspect and block on `requires_deploy_consent?` in `lib/agent_os/provisioner.ex`

**Checkpoint**: Deploy consent verification complete.

---

## Phase 5: User Story 4 - Capability Render badges (Priority: P3)

**Goal**: Present distinct legible badges for both flags in the inventory rendering.

**Independent Test**: Verify that external_send shows both badges, and safe local connectors show none.

### Implementation for User Story 4

- [ ] T006 [P] Add flag properties to the `Entry` struct in `lib/agent_os/capability_render/entry.ex`
- [ ] T007 [P] Refactor `danger_tier/1` and capability badge string formatting in `lib/agent_os/capability_render.ex` to surface both flags

**Checkpoint**: Badges legibility verified.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Purging legacy terms and testing complete battery

- [ ] T008 Update all ExUnit test files to remove any legacy `requires_approval?` references and assert the new split behaviors in `test/agent_os/`
- [ ] T009 Run `mix format` and `mix test` to ensure all tests pass and the codebase is clean
