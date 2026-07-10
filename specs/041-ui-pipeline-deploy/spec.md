# Feature Specification: UI-Driven Pipeline & Durable Deployments

**Feature Branch**: `041-ui-pipeline-deploy`
**Created**: 2026-07-08
**Status**: Draft
**Input**: User description: "Wire the web UI to the full generation pipeline (elicit → generate → judge → deploy → execute-on-trigger) and make deployment durable across power cycles."

## Overview

The generation pipeline works end-to-end but is headless: confirming an elicited
spec in the browser writes a file and stops — nothing invokes the pipeline, and the
pipeline has never been started by anything other than a hand-run script. Separately,
"deployed" is not a durable runtime concept: deployment writes only an audit record,
trigger dispatch fires for any manifest file on disk whether or not it was ever
deployed, and per-agent time triggers declared in manifests are ignored entirely
(one global config hour drives the scheduler). A power cycle silently loses all
trigger arming, and there is nothing to rehydrate from.

This feature closes both gaps: the whole loop — elicit, generate, judge, deploy
(consent-gated by default), execute on trigger — runs from the browser with live
progress, and a durable deployment registry makes "deployed" a first-class, restart-
surviving state that gates all trigger dispatch.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Confirmed spec runs the pipeline from the browser (Priority: P1)

After the elicitation conversation confirms a spec, the user chooses a review mode
for this run (default: consent-gated) and starts the pipeline without leaving the
browser. The UI stays responsive while the pipeline runs, and shows stage-by-stage
progress — manifest, synthesis, judging, security review, deploy — with verdicts as
they land and a clear terminal outcome: deployed, blocked pending consent, or
stopped with the reason.

**Why this priority**: This is the headline gap — the product's core loop exists but
cannot be driven by its own UI. Everything else in this feature refines what
"deployed" means; this story makes the loop reachable.

**Independent Test**: With stubbed model providers, confirm a spec in the elicitation
UI, choose a review mode, and observe the progress panel advance through all stages
to a terminal outcome; the pipeline record is queryable afterwards. The browser
session never blocks or times out while stages run.

**Acceptance Scenarios**:

1. **Given** a confirmed elicited spec in the elicitation UI, **When** the user
   starts the pipeline, **Then** the run begins without blocking the page, and the
   progress panel shows each stage transition and verdict as it happens.
2. **Given** a running pipeline, **When** a stage fails or a verdict is not pass,
   **Then** the progress panel shows where it stopped and why, and no deployment
   occurs.
3. **Given** the review-mode choice, **When** the user picks nothing, **Then** the
   run defaults to the permissions-dependent mode (review only if any requested
   grant is classified consent-requiring, per the connector registry's fixed danger
   classes); always-review is selectable, and the skip-review mode is never
   preselected.
4. **Given** a completed run, **When** the user later revisits the UI, **Then** the
   run's outcome and verdicts are still visible (persisted, not just ephemeral UI
   state).

---

### User Story 2 - Consent-gated deployment lands in the consent screen (Priority: P2)

With the default review mode, a pipeline that passes judging and security review does
not deploy silently: it parks as a pending approval. The existing consent screen
shows the agent's requested grants by danger tier; approving there completes the
deployment, and the pipeline progress panel and inventory reflect the deployed state.
Denying leaves the agent undeployed with a visible record.

**Why this priority**: Conferral of capability is a human act (Constitution X); the
UI loop is only trustworthy if the human gate is in the loop by default. Reuses the
existing consent surface — this story is wiring, not new UI.

**Independent Test**: Run a pipeline in consent-gated mode with stubs; verify it
terminates as blocked-pending-consent, appears in the consent screen, and that
approving there flips the agent to deployed (visible in inventory and the registry)
while denying leaves it undeployed.

**Acceptance Scenarios**:

1. **Given** a pipeline run in consent-gated mode with passing verdicts, **When** it
   reaches deployment, **Then** it parks as a pending approval and the progress panel
   shows blocked-pending-consent.
2. **Given** the parked deployment, **When** the user approves it in the consent
   screen, **Then** deployment completes through the existing approval-resume path,
   the deployment registry gains the agent, and the inventory shows it as deployed.
3. **Given** the parked deployment, **When** the user denies it, **Then** the agent
   is not deployed, is absent from the deployment registry, and the denial is
   recorded.
4. **Given** a pending deployment approval, **When** the system restarts before the
   user acts, **Then** the pending approval survives and can still be approved or
   denied afterwards.

---

### User Story 3 - Deployment is durable and gates all trigger dispatch (Priority: P1)

Deploying an agent records it in a durable deployment registry. Trigger dispatch —
time, event, and message — consults that registry: only registered, active agents
fire. On boot, the substrate reads the registry and re-arms each deployed agent's
declared triggers, including per-agent time triggers (which today are ignored in
favor of one global config hour). After a power cycle, every deployed agent is
listed, armed, and fires on its triggers with no manual re-arming.

**Why this priority**: Co-P1 with the UI wiring — without it, "deploy" from the UI
is a fiction that evaporates on restart, and undeployed manifests on disk can fire.
This is also the safety half: registry membership gates dispatch (though the
capability rail remains the only firewall).

**Independent Test**: Deploy an agent (stubs), verify a registry record exists; stop
and restart the substrate processes against the same stores; verify the agent is
still registered, its triggers are re-armed from its manifest, a fired trigger
produces a run, and a manifest that exists on disk but was never deployed does NOT
fire.

**Acceptance Scenarios**:

1. **Given** a successful deployment (direct or via consent approval), **When** it
   completes, **Then** a typed registry record exists (agent, manifest reference,
   deployed-at, provenance, active flag) in durable storage.
2. **Given** a manifest file on disk that was never deployed, **When** a matching
   event/message trigger arrives, **Then** no run starts and the refusal is
   observable.
3. **Given** a deployed agent with a declared time trigger, **When** the substrate
   boots, **Then** that agent's time trigger is armed from its manifest (not from
   the single global config hour) and fires at its declared time.
4. **Given** a deployed agent and a power cycle, **When** the substrate restarts,
   **Then** the agent appears in inventory as deployed and its event/message triggers
   fire exactly as before the restart, with no manual step.
5. **Given** trigger windows missed while powered off, **When** the substrate
   restarts, **Then** missed windows are NOT retroactively fired (no catch-up), and
   the next scheduled window fires normally.

---

### User Story 4 - Fire a trigger from the inventory (Priority: P3)

The inventory gains a per-agent "fire trigger" affordance for agents with a message
trigger: the user supplies a test payload, the run executes through the normal
trigger→run path, and the run's outcome and action tally become visible in the
inventory's run log afterwards.

**Why this priority**: Completes "execute on trigger" from the browser and gives a
demo/verification surface, but the loop is exercisable without it (real triggers
work once US3 lands).

**Independent Test**: For a deployed agent with a message trigger, submit a payload
from the inventory; verify a run starts through the normal dispatch path, and the
run log shows the outcome. Verify the affordance is absent or disabled for agents
without a message trigger and for undeployed agents.

**Acceptance Scenarios**:

1. **Given** a deployed agent with a message trigger, **When** the user fires it with
   a payload from the inventory, **Then** a run starts via the normal trigger path
   and its outcome appears in the run log.
2. **Given** an agent without a message trigger (or not deployed), **When** the user
   views it in inventory, **Then** no active fire affordance is offered.

---

### Edge Cases

- **Pipeline crash mid-run**: the progress panel shows stopped-with-reason from the
  persisted run record; the UI never hangs waiting for a dead run.
- **Concurrent pipeline runs**: starting a second elicitation/pipeline while one is
  running must not corrupt progress reporting; runs are identified individually.
  (Single-user prototype: simultaneous runs are allowed but need not be optimized.)
- **Browser refresh mid-run**: reloading the page rejoins the live progress of a
  still-running pipeline rather than losing it.
- **Redeploying an existing agent**: overwrites/updates the registry record rather
  than duplicating it; the previous record's history remains in provenance.
- **Registry record whose manifest file is missing at boot**: logged loudly, agent
  marked inactive rather than crashing boot or silently skipping.
- **Deny then re-run**: a denied deployment leaves the pipeline free to be re-run
  later for the same purpose without manual cleanup.
- **Legacy discovery schedule**: the existing config-driven daily run must keep
  working (or be explicitly migrated to the registry model) — no silent regression
  of the only currently-scheduled agent.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Confirming an elicited spec in the elicitation UI MUST offer starting
  the generation pipeline for that spec with a per-run review-mode choice, defaulting
  to the permissions-dependent mode (consent required exactly when a requested grant
  is classified consent-requiring by the substrate's connector registry); the
  skip-review mode requires explicit selection.
- **FR-002**: Starting the pipeline MUST NOT block the browser session; the UI
  remains responsive for the duration of the run.
- **FR-003**: The pipeline MUST emit live progress events (stage started/finished,
  verdicts, terminal outcome) that the UI renders as they occur; progress MUST also
  be reconstructable from persisted state after a refresh or reconnect.
- **FR-004**: A consent-gated run that passes judging and security review MUST park
  deployment as a pending approval visible in the existing consent screen; approval
  completes deployment via the existing approval-resume path; denial records the
  refusal and deploys nothing.
- **FR-005**: Every successful deployment (direct or approval-resumed) MUST write a
  typed record to a durable deployment registry: agent identity, manifest reference,
  deployment time, provenance, and an active flag. Redeployment updates the record;
  there is exactly one writer for the registry.
- **FR-006**: Trigger dispatch for ALL trigger types (time, event, message) MUST
  consult the deployment registry and fire only for registered, active agents. A
  manifest on disk without a registry record MUST NOT fire, and the refusal MUST be
  observable (logged).
- **FR-007**: On boot, the substrate MUST read the deployment registry and arm each
  active agent's declared triggers from its manifest, including per-agent time
  triggers. Missed windows are not fired retroactively.
- **FR-008**: The inventory MUST reflect deployment state from the registry (not
  from the mere existence of a manifest file) and MUST update live when deployments
  or pipeline outcomes change.
- **FR-009**: The inventory MUST offer a per-agent message-trigger test-fire with a
  user-supplied payload for deployed agents with a message trigger, routed through
  the normal trigger dispatch path, with the run outcome visible afterwards.
- **FR-010**: Pipeline progress events and deployment registry records MUST be typed
  values (no bare maps/strings crossing these boundaries).
- **FR-011**: Generation and judging remain uncapped one-off setup spend; runtime
  spend caps are unaffected by this feature.
- **FR-012**: All automated tests run without live model calls (provider stubs for
  pipeline stages) and without a live browser (UI flows verified by manual
  walkthrough; substrate behavior — registry, dispatch gating, re-arming, events —
  covered by backend tests against seeded stores).

### Key Entities

- **Deployment Record**: the registry entry making "deployed" durable — agent
  identity, manifest reference, deployed-at, provenance summary, active flag.
  Single-writer, durable, rehydrated at boot.
- **Pipeline Progress Event**: typed event published during a run — run identity,
  stage, status, verdict/outcome payload — consumed live by the UI and derivable
  from the persisted run record.
- **Pipeline Run Record** (existing): the persisted per-run outcome the UI reads
  for history and reconnection.
- **Pending Deployment Approval** (existing): the parked consent-gated deployment,
  already durable; this feature adds no new approval mechanics.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can go from a confirmed elicited spec to a deployed (or
  consciously consent-blocked) agent entirely in the browser, with zero terminal
  commands, watching every stage land.
- **SC-002**: 100% of trigger firings originate from registry-registered active
  agents; a never-deployed manifest on disk produces zero runs.
- **SC-003**: After a full substrate restart, 100% of previously deployed agents are
  listed as deployed and their triggers fire on the next occurrence with no manual
  re-arming; zero missed-window catch-up firings occur.
- **SC-004**: A consent-gated run never deploys without an explicit human approval;
  the approval survives a restart taken before the human acts.
- **SC-005**: A browser refresh during a running pipeline loses no information: the
  progress view reflects the true current stage within one update cycle.
- **SC-006**: The full test suite passes with no live model calls and no regression
  of the uncapped generation/judging spend behavior.

## Assumptions

- **Single-user, unauthenticated UI** as today; auth is out of scope.
- **Permissions-dependent review is the default mode** (user decision, revised from
  always-review during walkthrough prep): whether deployment blocks for consent
  follows the requested grants' registry-fixed danger classes — the deterministic
  envelope predicate. Per-run selection is offered in the UI; the dangerous
  skip-review mode is never pre-selected.
- **No catch-up** of time-trigger windows missed while powered off; the next window
  fires normally.
- **The legacy config-driven discovery schedule** keeps working during this feature;
  migrating discovery itself onto the registry model is acceptable but not required.
- **Live progress transport** reuses the substrate's existing (currently dormant)
  pub/sub facility; polling remains as a fallback where it already exists.
- **Registry gates dispatch, rail guards effects**: registry membership confers no
  capability; the capability rail remains the sole firewall (Constitution XI).
- **Concurrent pipeline runs** are permitted but not optimized (single-user
  prototype); progress events are keyed per run so parallel runs don't interleave
  incorrectly in the UI.

## Out of Scope

- Rewriting discovery as a deterministic agent (separate follow-up enabled by 040).
- Authentication/authorization on the web UI.
- Catch-up execution of time-trigger windows missed while powered off.
- Multi-node/distributed operation — single local BEAM node as today.
- Undeploy UI (registry supports an active flag; a dedicated undeploy surface is a
  follow-up).
