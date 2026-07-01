# Feature Specification: Standing Inventory Dashboard

**Feature Branch**: `024-standing-inventory-dashboard`  
**Created**: 2026-07-01  
**Status**: Draft  
**Input**: User description: "Implement roadmap plan 06-03 — Standing Inventory Dashboard: a Phoenix/LiveView page that renders the active agent roster, spend status, and audit logs for every provisioned agent, reading purely from the substrate's already-computed state (no communication with agent processes)."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Enumerate and View Provisioned Agent Roster (Priority: P1)

As an operator, I want to see a visual list of all provisioned agents, so that I can see their purpose, triggers, owner, supervision structure, deployment provenance, and a combined status line representing judge, security review, and conformance state.

**Why this priority**: Core MVP requirement to see who is active in the environment.

**Independent Test**: Render the `/inventory` page with `manifests/discovery.md` and check if the discovery agent card is shown with all required metadata fields.

**Acceptance Scenarios**:

1. **Given** one manifest `manifests/discovery.md` exists, **When** visiting `/inventory`, **Then** the page displays one roster card/row with the agent's purpose, triggers, owner/supervision, deploy provenance status, and combined status line.
2. **Given** two manifests exist in `manifests/`, **When** visiting `/inventory`, **Then** the page displays two roster cards/rows, one for each agent.

---

### User Story 2 - Real-Time Spend Tracking & Caps (Priority: P1)

As an operator, I want to see the spent amount vs. the cap per window for each agent formatted as USD dollars. The dashboard should clearly highlight visually when an agent is near or over its cap.

**Why this priority**: Core MVP requirement for monitoring spend constraints.

**Independent Test**: Seed the spend ledger with a specific spent value (near or over cap), and verify that the spent value is formatted as dollars and has an alert styling in the spend panel.

**Acceptance Scenarios**:

1. **Given** an agent manifest with cap 150,000 micro-dollars ($0.15) and spend-ledger containing 120,000 micro-dollars spent (80% of cap), **When** visiting `/inventory`, **Then** the UI shows "$0.120000 / $0.150000 per daily" with warning/breach styling indicating near-cap state.
2. **Given** an agent manifest with cap 100,000 micro-dollars ($0.10) and spend-ledger containing 110,000 micro-dollars spent (110% of cap), **When** visiting `/inventory`, **Then** the UI shows "$0.110000 / $0.100000 per daily" with a high-visibility breach alert indicating over-cap state.

---

### User Story 3 - Audit Log and Conformance/Approvals Panel (Priority: P2)

As an operator, I want to see the legible run trail for each agent (recent RunRecords including status, actions, triggers, input/dropped items, exit code / failure cause), conformance flags (health and trust axes), and any pending approvals.

**Why this priority**: Essential for auditing runtime behavior and checking for anomalies.

**Independent Test**: Seed the run log and conformance auditor state, and verify that the UI renders the recent run records, conformance flags, and pending approvals.

**Acceptance Scenarios**:

1. **Given** a run log file with recent status/actions lines and a conformance verdict indicating a trust or health flag, **When** visiting `/inventory`, **Then** the UI lists the recent run records and the conformance flag descriptions.
2. **Given** a pending approval ref exists for an agent, **When** visiting `/inventory`, **Then** the UI displays the pending approval ref and action details in the panel.

---

### User Story 4 - Live Refresh Polling (Priority: P2)

As an operator, I want the dashboard to automatically refresh without manual reload on a timed interval (polling) so that I can see the latest state as the substrate executes.

**Why this priority**: Keeps the dashboard up-to-date without inventing a complex PubSub broadcast layer.

**Independent Test**: Open the dashboard, update the backend state store/file, and verify the UI updates automatically after the timer tick.

**Acceptance Scenarios**:

1. **Given** a visitor has `/inventory` open, **When** a background run updates the run log, **Then** the UI updates to show the new run record after the next tick.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST scan `manifests/*.md` to enumerate active agents, keying each agent by `Path.basename(path, ".md")`.
- **FR-002**: System MUST extract a structured accessor `AgentOS.Inventory.data(opts)` returning all derived fields, and refactor `AgentOS.Inventory.render/1` to format that struct.
- **FR-003**: System MUST mount `AgentOSWeb.InventoryLive` at `/inventory`.
- **FR-004**: System MUST render a Roster panel containing purpose, triggers, owner/supervision, deploy provenance, and a combined status line (judge + security-review + conformance) for each agent.
- **FR-005**: System MUST render a Spend panel showing spent vs cap per window in formatted USD dollars (reusing micro-dollar conversion).
- **FR-006**: System MUST show a high-visibility visual warning (e.g. badge, color change) if spent is near (>= 80%) or over the cap.
- **FR-007**: System MUST render an Audit Log panel displaying recent run records (from `AgentOS.RunLog.read_records/2`), conformance flags (from `conformance` state store), and pending approvals (from `pending_approvals` state store).
- **FR-008**: System MUST perform live refresh using a timed poll (e.g. via `Process.send_after/3`) at a configurable or sensible default rate (e.g., 5 seconds).
- **FR-009**: System MUST reuse the `AgentOSWeb.Layouts` root layout and style via `priv/static/app.css` (no Tailwind/esbuild pipeline, plain static CSS).
- **FR-010**: All UI components on the `/inventory` route MUST be read-only (no control buttons or forms).

### Key Entities *(include if feature involves data)*

- **Agent Roster**: The list of provisioned agents derived from `manifests/*.md`.
- **Inventory Data**: The structured map/struct containing purpose, triggers, deploy provenance, mounts, spend, owner/supervision, last-run state, conformance, judge, security-review, and pending approvals.
- **Run Record**: Chronological trace of a single agent execution step parsed from the log file.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Visiting `/inventory` displays all provisioned agents with zero manual configuration.
- **SC-002**: Visual warnings for near/over cap spend are rendered correctly according to live data.
- **SC-003**: The UI automatically updates to reflect new runs or state changes within 5 seconds of the event.
- **SC-004**: System does not communicate with agent processes during rendering or polling (purely reads computed substrate state).

## Assumptions

- `manifests/*.md` exists and contains valid frontmatter.
- State stores are active and accessible via `AgentOS.StateStore.snapshot/1`.
- A background run log file is located at `data/run_log.md` (or a configured path).
