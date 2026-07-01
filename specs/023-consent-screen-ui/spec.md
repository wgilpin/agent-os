# Feature Specification: Consent Screen UI

**Feature Branch**: `023-consent-screen-ui`  
**Created**: 2026-07-01  
**Status**: Draft  
**Input**: User description: "Implement roadmap plan 06-02 — Consent Screen UI: a Phoenix/LiveView screen that renders the mechanical capability render for a manifest so a user can approve exact permission grants before the agent's code is deployed/executed (Phase 6 success criterion 2: \"A secure consent screen displays exact permission grants before code execution\")."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - View Deterministic Capability Grants (Priority: P1)

As a system owner, I want to view a deterministic capability rendering of a manifest before code execution, so that I can see the exact, un-paraphrased permissions and spend cap.

**Why this priority**: Core requirement for Phase 6 success criterion 2. The user must be shown the exact permissions before any code executes.

**Independent Test**: Load the consent page with a valid manifest query parameter. Verify that the exact phrases, danger tiers (with EXTERNAL highlighted), scoping parameters (methods/recipients), and spend cap are shown.

**Acceptance Scenarios**:

1. **Given** a valid manifest path `manifests/discovery.md` with read-only, local, and external grants, **When** visiting `/consent?manifest=manifests/discovery.md`, **Then** the screen displays the purpose, each capability's exact phrase, correct danger badges (highlighting EXTERNAL), scoping details, and the spend cap of $500,000.
2. **Given** a manifest containing a connector not registered in the registry, **When** visiting `/consent?manifest=path/to/bad_manifest.md`, **Then** the screen displays the raised registry lookup error instead of showing guessed or blank grants.

---

### User Story 2 - Approve/Reject Deployments (Priority: P1)

As a system owner, I want to explicitly approve or reject a pending deploy action, so that I can control whether the agent's code runs.

**Why this priority**: The consent screen must act as an enforcement gate, either unblocking deployment on approval or blocking it on rejection.

**Independent Test**: Mount the LiveView with a pending deploy action reference in `pending_approvals`. Click Approve and assert that the deploy action resumes. Click Reject and assert that deployment is aborted.

**Acceptance Scenarios**:

1. **Given** a pending deploy approval in the `pending_approvals` StateStore, **When** clicking the "Approve" button, **Then** the consent state is recorded as `:reviewed_human`, the approval is submitted to the TriggerGateway, and the agent's code execution starts.
2. **Given** a pending deploy approval, **When** clicking the "Reject" button, **Then** the approval is marked as denied, no code execution starts, and the UI transitions to a blocked/rejected state.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Mount a new LiveView `AgentOSWeb.ConsentLive` at `/consent` in `lib/agent_os_web/router.ex`.
- **FR-002**: Read the target manifest file path from the `manifest` query parameter (e.g. `/consent?manifest=manifests/discovery.md`).
- **FR-003**: Load the manifest from the file system using `AgentOS.Manifest.load/1`.
- **FR-004**: Retrieve capability entries from the loaded manifest using `AgentOS.CapabilityRender.entries/1`.
- **FR-005**: Render the exact `phrase`, `recipients`, and `methods` fields of each `Entry` verbatim without inventing or hardcoding copy.
- **FR-006**: Highlight the danger tier badges: `:read_only`, `:local`, and `:external`, ensuring that `:external` is visually emphasized as the high-risk tier.
- **FR-007**: Group or rank the capabilities so that external/mutating capabilities are positioned prominently.
- **FR-008**: Render the spend cap and period from `manifest.spend.cap` and `manifest.spend.window`.
- **FR-009**: Provide explicit "Approve" and "Reject" buttons.
- **FR-010**: On "Approve", record consent: update the agent's provenance StateStore status to `:reviewed_human` and submit `{:approval, :approve, ref}` to `AgentOS.TriggerGateway` (if a matching pending approval reference exists).
- **FR-011**: On "Reject", deny execution: submit `{:approval, :deny, ref}` to `AgentOS.TriggerGateway` (if a matching pending approval reference exists) and transition the UI state to rejected without running any code.
- **FR-012**: Surface any raised runtime errors from `entries/1` (e.g., missing connectors) on the UI as loud failures rather than swallowing them.
- **FR-013**: Reuse the `AgentOSWeb.Layouts` root layout and style the view using custom, premium plain CSS in `priv/static/app.css`. Keep JavaScript out of the template and keep it minimal as per `CLAUDE.md`.

### Key Entities

- **Manifest**: The declarative security manifest specifying purpose, grants, and spend limits.
- **Capability Render Entry**: The deterministic, typed presentation-layer representation of a capability grant.
- **Pending Approval**: A parked deploy or execution action held in the substrate's StateStore awaiting human decision.
- **Provenance**: The recorded deployment audit trail indicating human review status and manifest hashes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The consent screen renders all active manifest permissions, scopes, and spend limits deterministically within 50ms of loading.
- **SC-002**: 100% of approved actions correctly transition the agent's deploy status to `:reviewed_human` in the provenance store and trigger run execution.
- **SC-003**: 100% of rejected actions leave the agent's code unexecuted and mark the approval ref as deleted/denied.
- **SC-004**: 100% of missing registry lookups result in a visible raised error message, preventing unauthorized or guessed permission display.

## Assumptions

- The manifest path is supplied via the `manifest` query parameter (e.g., `/consent?manifest=manifests/discovery.md`).
- A matching pending approval is resolved by scanning the substrate's `pending_approvals` StateStore for an action whose method matches the loaded manifest path.
- In-memory StateStore states and test setups follow the conventions in `test/agent_os_web/elicitation_live_test.exs`.
