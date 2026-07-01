# Tasks: Standing Inventory Dashboard

**Input**: Design documents from `/specs/024-standing-inventory-dashboard/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4)
- Exact file paths are included in descriptions.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Route definition and initial setup

- [x] T001 Define and mount the `/inventory` route in `lib/agent_os_web/router.ex`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Accessor refactoring and unit testing (must be complete before LiveView pages)

- [x] T002 Refactor `lib/agent_os/inventory.ex` to extract the structured data accessor `data/1` and rewrite `render/1` to format its output
- [x] T003 [P] Add unit tests in `test/agent_os/inventory_test.exs` verifying that `Inventory.data/1` returns correct fields and matches output formatted by `render/1`

---

## Phase 3: User Story 1 - Enumerate and View Provisioned Agent Roster (Priority: P1) 🎯 MVP

**Goal**: Render cards for all provisioned manifests in the environment with core metadata

**Independent Test**: Mount the page and assert that `manifests/discovery.md` is rendered as a roster card with its purpose, triggers, owner/supervision, provenance, and status badges.

### Tests for User Story 1

- [x] T004 [P] [US1] Create the integration test suite in `test/agent_os_web/inventory_live_test.exs` and add setup/rendering assertions for the discovery agent roster card

### Implementation for User Story 1

- [x] T005 [US1] Create `lib/agent_os_web/live/inventory_live.ex` and implement basic `mount/3` and HTML templates to render the scanned agent roster
- [x] T006 [US1] Implement dynamic scanning of `manifests/*.md` in `lib/agent_os_web/live/inventory_live.ex` to populate roster entries dynamically
- [x] T007 [P] [US1] Style the layout, roster cards, and provenance/status badges in `priv/static/app.css`

---

## Phase 4: User Story 2 - Real-Time Spend Tracking & Caps (Priority: P1)

**Goal**: Render spent vs cap formatted in USD with alert/breach styles if near or over cap

**Independent Test**: Seed the spend ledger state store near cap (>=80%) or over cap (>=100%) and verify warning/breach css indicators are rendered.

### Tests for User Story 2

- [x] T008 [P] [US2] Add assertions to `test/agent_os_web/inventory_live_test.exs` verifying dollar formatting and near/over-cap warning indicators

### Implementation for User Story 2

- [x] T009 [US2] Implement the Spend Status template section in `lib/agent_os_web/live/inventory_live.ex` formatting spent vs cap values into USD dollars
- [x] T010 [P] [US2] Add styling for warning and breach states (colors, alert text) in `priv/static/app.css`

---

## Phase 5: User Story 3 - Audit Log and Conformance/Approvals Panel (Priority: P2)

**Goal**: Render run logs, conformance flags, and pending approvals for each agent

**Independent Test**: Seed the run log file, conformance store, and approvals store, and assert they render under the correct agent card.

### Tests for User Story 3

- [x] T011 [P] [US3] Add assertions to `test/agent_os_web/inventory_live_test.exs` to verify run records table, conformance flags, and pending approvals render correctly

### Implementation for User Story 3

- [x] T012 [US3] Implement RunRecords table rendering in `lib/agent_os_web/live/inventory_live.ex` using `AgentOS.RunLog.read_records/2`
- [x] T013 [US3] Implement Conformance Flags and Pending Approvals layout in `lib/agent_os_web/live/inventory_live.ex`
- [x] T014 [P] [US3] Style the run records table, conformance flag list, and capabilities list in `priv/static/app.css`

---

## Phase 6: User Story 4 - Live Refresh Polling (Priority: P2)

**Goal**: Poll and refresh dashboard state dynamically every 5 seconds

**Independent Test**: Assert that the page handles a `:tick` info message and triggers a re-fetch of agent data.

### Tests for User Story 4

- [x] T015 [P] [US4] Add tick/reload assertion to `test/agent_os_web/inventory_live_test.exs`

### Implementation for User Story 4

- [x] T016 [US4] Implement dynamic polling with `Process.send_after/3` on `:tick` in `lib/agent_os_web/live/inventory_live.ex`

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Format files, run suite, verify quickstart

- [x] T017 [P] Clean and format modified files using `mix format`
- [x] T018 Run the ExUnit suite `mix test` to verify all tests pass
- [x] T019 Run local verification on port 4000 as detailed in `specs/024-standing-inventory-dashboard/quickstart.md`

---

## Dependencies & Execution Order

### Phase Dependencies

* **Setup (Phase 1)**: No dependencies.
* **Foundational (Phase 2)**: Depends on T001 (Route setup) so tests can resolve.
* **User Story 1 (Phase 3)**: Depends on T002/T003 (data accessor extracted).
* **User Story 2 (Phase 4)**: Depends on User Story 1 roster card setup.
* **User Story 3 (Phase 5)**: Depends on User Story 1 roster card setup.
* **User Story 4 (Phase 6)**: Depends on User Story 1 roster card setup.
* **Polish (Phase 7)**: Depends on all user stories complete.

### Parallel Opportunities

* Setup `T001` and Refactoring `T002` can be started in parallel.
* CSS styles `T007`, `T010`, `T014` can be done together once the markup structure is defined.
* Test files `T004`, `T008`, `T011`, `T015` are contiguous updates in `test/agent_os_web/inventory_live_test.exs` that can be designed in parallel.

---

## Parallel Example: User Story 1

```bash
# Style card visual elements while LiveView layout is implemented:
Task: "Style the layout, roster cards, and provenance/status badges in priv/static/app.css"
Task: "Implement basic AgentOSWeb.InventoryLive layout and HTML templates in lib/agent_os_web/live/inventory_live.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Setup and Foundational refactoring (T001 - T003).
2. Complete User Story 1 Roster display (T004 - T007).
3. Validate by running `mix test test/agent_os_web/inventory_live_test.exs` on the roster card assertions.

### Incremental Delivery

1. Add Spend Tracking (US2) -> Verify dollar formatting & near/over cap CSS indicators.
2. Add Audit Log & Conformance (US3) -> Verify table and flag listings.
3. Add Polling (US4) -> Verify live refresh behavior.
4. Polish & format all code.
