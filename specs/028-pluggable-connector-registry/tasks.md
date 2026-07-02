# Tasks: Pluggable Connector Registry

**Input**: Design documents from `/specs/028-pluggable-connector-registry/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure

- [x] T001 Configure the `AgentOS.ConnectorSupervisor` `Task.Supervisor` child process in `lib/agent_os/application.ex`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core behaviour definition and dynamic auto-discovery registry that MUST be complete before user story work begins

- [x] T002 Define the `AgentOS.Connector` behaviour callbacks and registry APIs in `lib/agent_os/connector.ex`
- [x] T003 Implement dynamic module scanner in `lib/agent_os/connector.ex` to discover modules implementing the `AgentOS.Connector` behaviour at boot time

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Pluggable Connector Registry (Priority: P1) 🎯 MVP

**Goal**: Extensible connector registry using dynamic auto-discovery of self-contained modules under `lib/agent_os/connector/` without editing any central lists.

**Independent Test**: Dropping a mock connector module into `lib/agent_os/connector/` and asserting that `AgentOS.Connector.registry/0` dynamically contains its metadata at boot.

### Implementation for User Story 1

- [x] T004 [P] [US1] Create behaviour connector module for `kv_append` in `lib/agent_os/connector/kv_append.ex`
- [x] T005 [P] [US1] Create behaviour connector module for `external_send` in `lib/agent_os/connector/external_send.ex`
- [x] T006 [P] [US1] Create behaviour connector module for `gmail_read` in `lib/agent_os/connector/gmail_read.ex`
- [x] T007 [P] [US1] Create behaviour connector module for `gmail_draft` in `lib/agent_os/connector/gmail_draft.ex`
- [x] T008 [US1] Delegate manifest projection mapping in `lib/agent_os/manifest/projection.ex` to `scope/1` callbacks of discovered connector modules
- [x] T009 [US1] Delegate capability rendering in `lib/agent_os/capability_render.ex` to `render/1` callbacks of discovered connector modules

**Checkpoint**: User Story 1 is fully functional and testable independently.

---

## Phase 4: User Story 2 - Generic Post-Approval Credential Injection (Priority: P2)

**Goal**: Dynamically resolve and inject credentials post-approval based on the declared ID in the connector's metadata.

**Independent Test**: Execute a credential-reliant connector and verify the secret is resolved and injected post-approval without naming-based checks.

### Implementation for User Story 2

- [x] T010 [US2] Implement generic environment variable lookup logic in `lib/agent_os/credential_source.ex`
- [x] T011 [US2] Implement dynamic secret resolution post-approval at the effector injection point in `lib/agent_os/effector.ex`

**Checkpoint**: User Stories 1 and 2 work together, and credential injection is fully generic.

---

## Phase 5: User Story 3 - Fault-Contained Action Execution (Priority: P3)

**Goal**: Contain crashes and infinite hangs of connector execution within a supervisor timebox.

**Independent Test**: Execute a connector that crashes or blocks, verifying that execution terminates safely and returns a fail-closed error.

### Implementation for User Story 3

- [x] T012 [US3] Implement dynamic dispatch and timeboxed/isolated execution in `lib/agent_os/effector.ex` using `AgentOS.ConnectorSupervisor` and a rescue/catch block

**Checkpoint**: All user stories are now independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Verification, testing, and compliance checks

- [x] T013 Create test suite for registry discovery, credential injection, and crash/timeout isolation in `test/agent_os/connector_test.exs`
- [x] T014 Run existing test suite and world-B verification battery via command `mix test` to confirm everything stays green
- [x] T015 Validate documentation and quickstart code in `specs/028-pluggable-connector-registry/quickstart.md`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately.
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories.
- **User Stories (Phases 3+)**: All depend on Foundational phase completion.
  - User Story 1 (P1) must complete before Projection and Rendering delegation tasks.
  - User Story 2 (P2) depends on dynamic registry configuration.
  - User Story 3 (P3) depends on dynamic registry lookup and effector refactoring.
- **Polish (Phase 6)**: Depends on all user stories being complete.

---

## Parallel Example: User Story 1

```bash
# Implement connector modules in parallel:
Task: "Create behaviour connector module for kv_append in lib/agent_os/connector/kv_append.ex"
Task: "Create behaviour connector module for external_send in lib/agent_os/connector/external_send.ex"
Task: "Create behaviour connector module for gmail_read in lib/agent_os/connector/gmail_read.ex"
Task: "Create behaviour connector module for gmail_draft in lib/agent_os/connector/gmail_draft.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1 (Setup) and Phase 2 (Foundational).
2. Create dynamic connector behaviour modules (T004-T007).
3. Verify that dynamic auto-discovery registry is fully functional.
4. Delegate projection and rendering logic (T008-T009).
