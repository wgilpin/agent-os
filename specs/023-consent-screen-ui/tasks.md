# Tasks: Consent Screen UI

**Input**: Design documents from `/specs/023-consent-screen-ui/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/consent-ui.md

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Verify dependencies and convention setup.

- [x] T001 Verify the project routing structure and layout conventions in lib/agent_os_web/router.ex

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core CSS structure and base route registrations.

- [x] T002 Add base CSS selectors and variables for consent badges and layout at the bottom of priv/static/app.css
- [x] T003 Mount the new LiveView route for ConsentLive in lib/agent_os_web/router.ex

**Checkpoint**: Foundation ready - LiveView mount point and initial styling scaffolding are configured.

---

## Phase 3: User Story 1 - View Deterministic Capability Grants (Priority: P1) 🎯 MVP

**Goal**: Render manifest capability entries, scoping parameters, and spend cap with correct danger badges, plus handle registry exceptions loudly on the screen.

**Independent Test**: Mount the LiveView with a valid manifest query parameter (`/consent?manifest=manifests/discovery.md`). Assert that it renders the manifest's purpose, exact deterministic phrases for all capability grants, appropriate danger badges (with `:external` emphasized), scope properties (methods and recipients), and the spend cap. Ensure a manifest with a missing registry connector displays a loud error message instead of guessed grants.

### Tests for User Story 1

- [x] T004 [P] [US1] Create integration test boilerplate for rendering capabilities in test/agent_os_web/consent_live_test.exs
- [x] T005 [P] [US1] Create LiveView controller boilerplate for AgentOSWeb.ConsentLive in lib/agent_os_web/live/consent_live.ex

### Implementation for User Story 1

- [x] T006 [US1] Implement manifest loading using AgentOS.Manifest.load/1 in lib/agent_os_web/live/consent_live.ex
- [x] T007 [US1] Retrieve capability entries using AgentOS.CapabilityRender.entries/1 in lib/agent_os_web/live/consent_live.ex
- [x] T008 [US1] Sort capability list by danger level and format badges (:external, :local, :read_only) in lib/agent_os_web/live/consent_live.ex
- [x] T009 [US1] Implement render block for capability details, scoping, and spend cap in lib/agent_os_web/live/consent_live.ex
- [x] T010 [US1] Implement exception rescue in mount/3 to display unregistered connector errors on screen in lib/agent_os_web/live/consent_live.ex
- [x] T011 [US1] Style the capability list structure, danger levels, and badging layout in priv/static/app.css
- [x] T012 [US1] Add assertions for exact phrases, EXTERNAL badge, scoping parameters, and spend cap in test/agent_os_web/consent_live_test.exs
- [x] T013 [US1] Add assertions for unregistered connector registry lookup loud-failure display in test/agent_os_web/consent_live_test.exs

**Checkpoint**: At this point, User Story 1 is fully functional and can deterministically render any manifest and its capabilities, and catch connector errors.

---

## Phase 4: User Story 2 - Approve/Reject Deployments (Priority: P1)

**Goal**: Provide explicit Approve and Reject buttons, recording human consent and submitting approval resume signals to TriggerGateway.

**Independent Test**: Mount the LiveView with a pending approval reference. Click Approve and verify it records provenance as `:reviewed_human` and submits approval to TriggerGateway. Click Reject and verify it denies the execution and transitions the UI.

### Tests for User Story 2

- [x] T014 [P] [US2] Implement integration tests for the Approve/Reject button clicks and StateStore assertions in test/agent_os_web/consent_live_test.exs

### Implementation for User Story 2

- [x] T015 [US2] Link pending approval reference inside mount/3 by scanning pending approvals in lib/agent_os_web/live/consent_live.ex
- [x] T016 [US2] Implement the "approve" click handler that records provenance and submits approval to TriggerGateway in lib/agent_os_web/live/consent_live.ex
- [x] T017 [US2] Implement the "reject" click handler that submits deny signal to TriggerGateway in lib/agent_os_web/live/consent_live.ex
- [x] T018 [US2] Render Approve/Reject button controls and confirmation/alert messages in lib/agent_os_web/live/consent_live.ex
- [x] T019 [US2] Style action buttons, confirm states, and rejected states in priv/static/app.css

**Checkpoint**: All user stories are now independently functional. Approvals resume executions and rejections block them.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Format clean-up, compilation checks, and visual sanity checks.

- [x] T020 Run formatting and clean up code styling conventions via mix format
- [x] T021 Run final validation checklist using the quickstart.md instructions

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately.
- **Foundational (Phase 2)**: Depends on Setup completion. Blocks all user stories.
- **User Stories (Phase 3+)**: All depend on Foundational phase completion.
  - User Story 1 (P1) is the MVP and must be completed before starting User Story 2.
- **Polish (Phase 5)**: Depends on all user stories being complete.

---

## Parallel Example: User Story 1

```bash
# Launch integration test boilerplate and controller boilerplate in parallel:
Task: "Create integration test boilerplate for rendering capabilities in test/agent_os_web/consent_live_test.exs"
Task: "Create LiveView controller boilerplate for AgentOSWeb.ConsentLive in lib/agent_os_web/live/consent_live.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: Verify rendering and error surfacing via test/agent_os_web/consent_live_test.exs.

### Incremental Delivery

1. Foundation ready.
2. Add User Story 1 -> Verify rendering -> MVP complete.
3. Add User Story 2 -> Verify interactive approval & TriggerGateway signals.
4. Polish and format.
