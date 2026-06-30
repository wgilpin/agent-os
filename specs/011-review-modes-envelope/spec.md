# Feature Specification: Review Modes and Deterministic Envelope Predicate

**Feature Branch**: `011-review-modes-envelope`  
**Created**: 2026-06-30  
**Status**: Draft  
**Input**: User description: "Review modes + deterministic envelope predicate — a deploy-time rail that governs whether deploying an agent (provisioning it from its manifest) must BLOCK on a human, via three modes: --always-review (the v3-launch default) | --review-if-risky | --dangerously-skip-review. The 'risky-or-not' decision is a DETERMINISTIC ENVELOPE PREDICATE over manifest fields (read-only / no-egress / spend-under-threshold), never an LLM judgement. All three modes sit strictly ABOVE the runtime gate and NONE of them is permission to cross it; every deploy records its provenance (reviewed=human | skipped-in-envelope | dangerously-skipped) legibly in the standing inventory (roadmap plan 04-03, Phase 4 Generation MVP; Phase-4 success criterion 5; Constitution X 'capabilities are declared, never self-conferred' and XI 'the gate is the only firewall')."

## Clarifications

### Session 2026-06-30
- Q: What is the precise spend threshold for "spend-under-threshold", and which capability danger tiers count as read-only and no-egress? → A: Spend threshold is 100,000 micro-dollars ($0.10 USD). Read-only means `mutating? == false`. No-egress means danger tier is not `:external` (allowing only `:read_only` and `:local`).
- Q: Under `--review-if-risky`, does a conformance flag make an agent ineligible for skipped review? → A: Only `:gate_breach` (tripwire severity) conformance flags block auto-deploy. Other flags (health: quiet, sick) are ignored.


## User Scenarios & Testing *(mandatory)*

### User Story 1 - Always Review Deployments (Priority: P1)

An administrator deploys an agent under the `--always-review` mode (the default). The deployment process must halt and block on human approval, rendering the capability view to the human. Once approved by a human, the agent is deployed, and the provenance is recorded as `reviewed=human`.

**Why this priority**: It is the default safe mode, ensuring every deployment is explicitly reviewed by a human before execution.

**Independent Test**: Deploy an agent with `--always-review`. Verify that it does not execute automatically, parks for approval, shows the capability list to the human, and records `reviewed=human` in the inventory upon approval.

**Acceptance Scenarios**:

1. **Given** an agent manifest and the deploy mode set to `--always-review`, **When** the deployment is triggered, **Then** the deployment blocks and registers a pending approval event.
2. **Given** a blocked deployment under `--always-review`, **When** a human approves the deployment via the trigger gateway, **Then** the deployment is completed and its provenance is recorded as `reviewed=human`.

---

### User Story 2 - Review If Risky Deployments (Priority: P2)

An administrator deploys an agent under the `--review-if-risky` mode. The system automatically evaluates the manifest against a deterministic envelope predicate. If the manifest is within the envelope (and has no flagged history), it deploys without human intervention, recording provenance as `skipped-in-envelope`. If it is outside the envelope (or flagged), it blocks on human approval exactly like Story 1.

**Why this priority**: Improves operational velocity by auto-approving low-risk agents while preserving safety for high-risk ones.

**Independent Test**: Deploy a read-only agent under `--review-if-risky` and verify it deploys instantly (provenance `skipped-in-envelope`). Deploy an agent with egress capability under the same mode and verify it blocks on human approval.

**Acceptance Scenarios**:

1. **Given** a manifest within the envelope and no flagged history, **When** deployed with `--review-if-risky`, **Then** it is deployed without blocking and records provenance as `skipped-in-envelope`.
2. **Given** a manifest outside the envelope, **When** deployed with `--review-if-risky`, **Then** it blocks on human approval.

---

### User Story 3 - Dangerously Skip Review (Priority: P3)

An administrator deploys an agent under the `--dangerously-skip-review` mode. The deployment proceeds immediately without human approval, regardless of risk. However, the runtime safety gate still restricts the agent's actions strictly to the manifest grants at runtime.

**Why this priority**: Useful for fully automated testing or high-velocity environments where deploy-time blocking is undesirable, while maintaining runtime protection.

**Independent Test**: Deploy an agent outside the envelope under `--dangerously-skip-review`. Verify that it deploys without blocking (provenance `dangerously-skipped`) but still blocks ungranted actions at runtime.

**Acceptance Scenarios**:

1. **Given** an agent deployed under `--dangerously-skip-review`, **When** it attempts to execute a capability not granted by its manifest, **Then** the runtime gate blocks the action.

---

### Edge Cases

- **First-time Deployment**: How does the system handle conformance history check under `--review-if-risky` for an agent with no past execution? The conformance auditor has insufficient data, so only the manifest envelope predicate governs.
- **Drift or Manifest Breach at Runtime**: How does the system handle manifest breaches at runtime under `--dangerously-skip-review`? The safety gate must block the breach, proving the review mode is not a runtime bypass.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST support three deploy-time review modes: `--always-review` (default), `--review-if-risky`, and `--dangerously-skip-review`.
- **FR-002**: The review modes MUST sit strictly above the runtime gate; no review mode shall permit crossing the runtime gate or bypassing manifest enforcement.
- **FR-003**: The deterministic envelope predicate MUST evaluate whether a manifest is within the envelope based strictly on:
  - Read-only status: grants mutate no state.
  - No-egress status: grants permit no send or outbound egress.
  - Spend-under-threshold: spend cap is below a defined threshold.
- **FR-004**: The spend threshold and capability danger definitions MUST be deterministic and sourced from the connector capability registry. The spend threshold is 100,000 micro-dollars ($0.10 USD). "Read-only" is defined as `mutating? == false` (danger tier `:read_only`). "No-egress" is defined as a danger tier that is not `:external` (allowing only `:read_only` and `:local` danger tiers).
- **FR-005**: Under `--review-if-risky`, only `:gate_breach` (tripwire severity) conformance flags in the auditor's history make the agent ineligible for skipped review (forcing a human block on re-deployment). Other flags (such as `:quiet` or `:sick` health flags) do not block auto-deploy if the manifest matches the envelope.
- **FR-006**: The system MUST record the provenance of every deployment in the standing inventory as one of: `reviewed=human`, `skipped-in-envelope`, or `dangerously-skipped`.
- **FR-007**: The standing inventory render MUST display the recorded provenance alongside the capability and conformance views.
- **FR-008**: The capability render (04-01) MUST always be displayed at deploy time in every mode.
- **FR-009**: The logic of the envelope predicate, review modes, and provenance MUST be agent-agnostic and operate over generic manifest fields and the connector registry.

### Key Entities *(include if feature involves data)*

- **Deploy Provenance**: The record of how an agent was deployed, capturing the mode and approval status (`reviewed=human`, `skipped-in-envelope`, or `dangerously-skipped`).
- **Envelope Predicate**: A pure boolean evaluator that checks the manifest's read-only, no-egress, and spend-under-threshold status.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of deployments under `--always-review` block on human approval.
- **SC-002**: 100% of deployments under `--review-if-risky` bypass human approval if they meet the envelope predicate and are clean, but block if they do not.
- **SC-003**: 100% of deployments under `--dangerously-skip-review` deploy instantly.
- **SC-004**: 100% of manifest breaches at runtime are blocked, regardless of the deploy review mode.
- **SC-005**: Every deployment records its correct provenance in the standing inventory.

## Assumptions

- The connector registry defines the danger profiles of all available connectors.
- The trigger gateway's approval-as-event-trigger mechanism is reused to handle blocked deploys.
- Conformance auditor outputs are accessible from the conformance store.
