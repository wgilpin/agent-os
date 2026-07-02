# Tasks: Connector Admission + Compile-Isolated Plugins

**Input**: Design documents from `/specs/030-connector-admission/`
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

- [ ] T001 Verify project compiles and format is correct on the current branch `030-connector-admission`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core database setup for admission lists

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [ ] T002 Add the `"admitted_plugins"` StateStore mount to the supervisor tree in `lib/agent_os/application.ex`

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Contract Isolation (Priority: P1) 🎯 MVP

**Goal**: Connectors return described effects; substrate applies them at the chokepoint.

**Independent Test**: Verify `kv_append` mutates state via effector intercept, and all world-B tests stay green.

### Implementation for User Story 1

- [ ] T003 Refactor `AgentOS.Effector` to intercept and apply returned state store effect tuples in `lib/agent_os/effector.ex`
- [ ] T004 [P] Migrate `kv_append` connector to return a described effect tuple instead of calling `StateStore` directly in `lib/agent_os/connector/kv_append.ex`

**Checkpoint**: Contract isolation MVP complete.

---

## Phase 4: User Story 2 & 3 - Compile Isolation & Dynamic Loading (Priority: P2)

**Goal**: Support compiling plugin code in separate units and loading `.beam` files dynamically.

**Independent Test**: Load a precompiled `.beam` binary from the plugins directory.

### Implementation for User Stories 2 & 3

- [ ] T005 Implement dynamic directory scanning and module loading from `.beam` files in `lib/agent_os/connector.ex`
- [ ] T006 Integrate dynamic scanning inside `discover_and_build_registry` in `lib/agent_os/connector.ex`

**Checkpoint**: Dynamic loading and compile isolation verified.

---

## Phase 5: User Story 4 - Admission Gate & Credential Provisioning (Priority: P3)

**Goal**: Filter registry by admission status; wire dynamic credential mappings.

**Independent Test**: Connectors require explicit admission before they can be discovered or run.

### Implementation for User Story 4

- [ ] T007 Implement `admit/2` and `admitted?/1` roster validation logic in `lib/agent_os/connector.ex`
- [ ] T008 Update `discover_and_build_registry` and `get_module/1` to filter out un-admitted modules in `lib/agent_os/connector.ex`
- [ ] T009 Update `CredentialProxy` to dynamically resolve admitted plugin credential mappings at runtime in `lib/agent_os/credential_proxy.ex`

**Checkpoint**: Admission gate and dynamic credential proxy validation complete.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Validation and final code formatting

- [ ] T010 Create integration tests covering standalone plugin compilation, beam loading, admission gating, secret wiring, and effector intercept in `test/agent_os/connector_admission_test.exs`
- [ ] T011 Run `mix format` and `mix test` to ensure all tests pass and are clean
