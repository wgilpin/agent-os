# Tasks: Secure Secret Provisioning

**Input**: Design documents from `/specs/020-secure-secret-provisioning/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md

**Tests**: Tests are included under the Test-Driven Backend principle.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- Paths assume a single project structure under `lib/agent_os/` and `test/agent_os/` at the repository root.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Initial project environment configuration.

- [x] T001 [P] Remove compile-time env reads for `MODEL_KEY` and `OUTBOUND_TOKEN` from `config/config.exs` and set main credentials to `%{}` (retaining `:test` config intact)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core resolver implementation which MUST be complete before any user story can be implemented.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T002 Implement credential resolver `AgentOS.CredentialSource` in `lib/agent_os/credential_source.ex` with `.env` stream parsing, System environment reading, and filtering of nil/blank/whitespace values
- [x] T003 [P] Create unit tests for resolver `AgentOS.CredentialSource` in `test/agent_os/credential_source_test.exs` validating parsing, environment fallback, and validation checks

**Checkpoint**: Foundation ready - user story implementation can now begin in parallel.

---

## Phase 3: User Story 1 - Dynamic Runtime Loading of Model Keys (Priority: P1) 🎯 MVP

**Goal**: Load model API keys dynamically at runtime from environment variables and feed them to `CredentialProxy`.

**Independent Test**: Verify that starting the application with runtime OS environment variables loads keys into `CredentialProxy` and allows successful model queries.

### Implementation for User Story 1

- [x] T004 [US1] Update `AgentOS.CredentialProxy` in `lib/agent_os/credential_proxy.ex` to initialize state from `AgentOS.CredentialSource.resolve_credentials/0`
- [x] T005 [US1] Update test suite `test/agent_os/credential_proxy_test.exs` to align with the dynamic initialization of `CredentialProxy`
- [x] T006 [US1] Update `AgentOS.Application` in `lib/agent_os/application.ex` to replace the custom inline `.env` parser with `AgentOS.CredentialSource.resolve_credentials/0`

**Checkpoint**: User Story 1 should be fully functional and testable independently.

---

## Phase 4: User Story 2 - Fail-Closed on Missing/Empty Secrets (Priority: P2)

**Goal**: Securely block any inference attempts with missing/empty secrets and output startup warnings.

**Independent Test**: Start application with blank key, verify startup warning log, and verify that inference calls return `{:error, ...}` instead of making HTTP requests.

### Implementation for User Story 2

- [x] T007 [US2] Update `AgentOS.Application` in `lib/agent_os/application.ex` to log a critical error diagnostic at boot if `:model_key` is missing or blank
- [x] T008 [US2] Add a check in `real_provider_fn/3` in `lib/agent_os/inference_broker.ex` to return `{:error, :missing_credential}` if the passed secret is `nil`, `""`, or contains only whitespace
- [x] T009 [P] [US2] Add test cases in `test/agent_os/credential_source_test.exs` specifically verifying that empty/whitespace-only environment keys are correctly filtered and excluded

**Checkpoint**: User Stories 1 AND 2 should both work independently.

---

## Phase 5: User Story 3 - Python Sandbox Secret Isolation (Priority: P3)

**Goal**: Prevent host API keys from crossing the port boundary into sandboxed python agents.

**Independent Test**: Run python workload and verify `MODEL_KEY` is not present in its environment.

### Implementation for User Story 3

- [x] T010 [US3] Update `Port.open/2` call in `AgentOS.PortRunner` in `lib/agent_os/port_runner.ex` to include `env: [{"MODEL_KEY", false}, {"OUTBOUND_TOKEN", false}]`
- [x] T011 [US3] Add a test in `test/agent_os/elicitation_test.exs` or similar to verify that agent containers run without host environment secrets

**Checkpoint**: All user stories should now be independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Format, lint, and run the entire test suite.

- [x] T012 [P] Format codebase using `mix format` and check code quality using Credo
- [x] T013 run `mix test` to confirm all 224+ tests pass cleanly

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup completion.
- **User Stories (Phase 3+)**: All depend on Foundational phase completion.
- **Polish (Final Phase)**: Depends on all desired user stories being complete.

### Parallel Opportunities

- T001, T003, T009, T012 can run in parallel.
- Once Foundational phase completes, all user stories can proceed in parallel (or priority order).
