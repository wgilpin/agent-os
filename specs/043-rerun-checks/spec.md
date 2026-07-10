# Feature Specification: Re-run Checks for Existing Agents

**Feature Branch**: `043-rerun-checks`
**Created**: 2026-07-10
**Status**: Draft
**Input**: User description: "Re-run checks for existing agents: a recovery path for agents whose judge/security-review verdicts are missing, stale, or failed. Add a partial-pipeline entry point that re-runs stage 3 (blind compliance judge) and stage 5 (security review) against an agent's EXISTING generated code and manifest — no elicitation, no code regeneration — persisting fresh verdicts keyed to the current code hash. Surface it as a 'Re-run checks' action on the inventory card and as the suggested remedy when the consent page's deploy gate refuses an approval. Recovery must go through the checks, never around them: a re-run that fails still leaves the agent blocked, with the failure reason visible. Progress/outcome should be visible in the UI like a normal pipeline run."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Recover an agent stranded by an incomplete check (Priority: P1)

An agent was created and its code generated, but a transient failure (a crash mid-review, an interrupted run, a since-fixed bug in the checking machinery) meant its safety checks never recorded a verdict. The deploy gate now refuses to let it deploy or run. The owner opens the inventory, sees why the agent is blocked, and triggers "Re-run checks". The system re-examines the agent's existing code and manifest with the same compliance and security checks a new agent gets. When both pass, the agent becomes approvable and runnable through the normal flow — nothing was waived.

**Why this priority**: This is the reason the feature exists. Without it, a transient failure permanently strands an agent, and the only remedy is deleting it and repeating the entire creation conversation and generation — real cost and real frustration for an agent whose code is perfectly fine.

**Independent Test**: Can be fully tested by taking an agent with generated code but no recorded verdicts, triggering a re-run, and confirming the agent transitions to approvable/runnable when the checks pass.

**Acceptance Scenarios**:

1. **Given** an agent with generated code and no recorded check verdicts, **When** the owner triggers "Re-run checks" and both checks pass, **Then** fresh verdicts are recorded for the code that was examined and the agent can be approved and run through the normal flow.
2. **Given** an agent whose recorded verdicts no longer match its current code, **When** the owner triggers "Re-run checks" and both checks pass, **Then** the verdicts are refreshed for the current code and the agent is no longer blocked for staleness.
3. **Given** an agent blocked by the deploy gate, **When** the owner has NOT re-run checks, **Then** the agent remains blocked — the recovery action is the only path back, and it goes through the checks.

---

### User Story 2 - A failed re-run keeps the agent blocked, visibly (Priority: P2)

The owner re-runs checks on an agent and one of the checks fails (for example, the security review finds the code reaches outside its granted capabilities). The agent stays blocked. The owner can see which check failed and why, and can decide to delete the agent or re-create it.

**Why this priority**: Recovery must never become a bypass. The feature is only safe if a red result is as durable and as visible as a green one.

**Independent Test**: Can be tested by re-running checks on an agent whose code violates its manifest and confirming it remains blocked with the failure reason shown.

**Acceptance Scenarios**:

1. **Given** an agent whose code fails a check, **When** the owner re-runs checks, **Then** the agent remains blocked from approval and running, and the specific failing check and its reasoning are visible.
2. **Given** a re-run that itself fails to complete (crash, interruption), **When** the owner views the agent, **Then** the agent remains blocked exactly as before and the incomplete outcome is visible; the owner can retry.

---

### User Story 3 - The gate refusal points to the remedy (Priority: P3)

The owner tries to approve an agent and the deploy gate refuses (checks missing, stale, or failed). Instead of a dead end, the refusal message tells the owner what to do next: re-run the checks (or re-create/delete the agent when there is no code to check).

**Why this priority**: Discoverability. The recovery path exists after P1, but users encountering the gate should be routed to it without needing to know the system's internals.

**Independent Test**: Can be tested by attempting approval of a gate-refused agent and confirming the refusal message offers the re-run remedy for agents with code, and re-create/delete for agents without.

**Acceptance Scenarios**:

1. **Given** an agent with code refused by the deploy gate, **When** the owner sees the refusal, **Then** the message explains the reason and offers "Re-run checks" as the next step.
2. **Given** an agent with no generated code refused by the gate, **When** the owner sees the refusal, **Then** the message directs them to re-create or delete the agent (re-running checks is not offered — there is nothing to check).

---

### User Story 4 - Progress and history like a normal pipeline run (Priority: P3)

While a re-run is underway, the owner sees its progress the same way they see a new agent's pipeline: which check is running, then the outcome of each. The re-run is recorded so the owner can later see when checks were last re-run and what the result was.

**Why this priority**: Trust and transparency; the checks take real time and cost real money, and a silent spinner (or nothing) would look broken.

**Independent Test**: Can be tested by triggering a re-run and observing stage-by-stage progress and a persisted record of the outcome.

**Acceptance Scenarios**:

1. **Given** a triggered re-run, **When** the owner watches the UI, **Then** they see each check start and finish with its outcome, without needing to refresh.
2. **Given** a completed re-run, **When** the owner returns later, **Then** the outcome is still visible in the agent's history.

---

### Edge Cases

- Agent has a manifest but no generated code (orphan): re-run is not offered/refused with a clear message — there is nothing to check; remedy remains re-create or delete.
- Substrate-owned (system) agents: not eligible for re-run; they are not user-managed.
- Checks already green for the current code: re-run is not offered — it would spend money to change nothing; editing or regenerating the code re-opens the recovery path.
- A re-run is triggered while another re-run or pipeline run for the same agent is already underway: the second request is refused with a clear message (one at a time per agent).
- The agent's code changes while a re-run is in flight: the verdicts are tied to the code version that was actually examined, so changed code remains blocked as stale.
- Checks pass but the agent was never approved by the owner: it still requires normal human approval — a green re-run restores eligibility, not consent.
- A deployed, previously green agent goes red on a re-run: it stays deployed but the gate blocks its subsequent runs; the red verdicts and reasons are visible.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The owner MUST be able to trigger a "Re-run checks" action for any user-managed agent that has generated code and whose checks are not already green for that code, from the agent's inventory card. When both checks already pass for the current code there is nothing to recover, and the action is not offered (a request is refused with an explanatory message).
- **FR-002**: A re-run MUST execute the same compliance check (blind judge) and security review that a newly created agent undergoes, against the agent's existing code and manifest, with no re-elicitation and no code regeneration.
- **FR-003**: A completed re-run MUST persist fresh verdicts associated with the exact code version that was examined, replacing the agent's previous verdicts.
- **FR-004**: An agent whose re-run passes both checks MUST become eligible for approval and running through the existing gate — the re-run itself MUST NOT deploy, approve, or run the agent.
- **FR-005**: An agent whose re-run fails or does not complete MUST remain blocked exactly as before, with the specific failing check (or the incompleteness) and its reasoning visible to the owner.
- **FR-006**: When the deploy gate refuses an approval, the refusal message MUST name the reason and offer the appropriate remedy: re-run checks for agents with code; re-create or delete for agents without code.
- **FR-007**: Re-run progress MUST be visible in the UI as it happens (per-check start/finish and outcome), and the outcome MUST remain visible afterwards as part of the agent's history.
- **FR-008**: Re-run MUST be refused for agents with no generated code and for substrate-owned (system) agents, with an explanatory message.
- **FR-009**: At most one re-run or pipeline run per agent MUST be in flight at a time; a concurrent request is refused with a clear message.

### Key Entities

- **Agent**: A user-created automation with a manifest (purpose, grants, spend rules) and generated code. Its eligibility to deploy/run depends on check verdicts.
- **Check verdicts**: The recorded outcomes of the compliance check and the security review, each tied to the specific code version examined. Both must pass, for the current code, for the gate to open.
- **Check re-run**: A user-triggered examination of an existing agent — a record of when it ran, what code version it examined, each check's outcome, and why.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An agent stranded by an incomplete check can be restored to a runnable state with a single user action (plus the normal approval), with no re-elicitation and no code regeneration.
- **SC-002**: There is no path by which an agent with failed, missing, or stale checks becomes runnable without both checks passing for its current code — including via this recovery feature.
- **SC-003**: An owner looking at a blocked agent can determine why it is blocked and what to do next entirely from the UI, without reading server logs.
- **SC-004**: A re-run's cost is bounded by the checking steps alone — it never incurs the cost of re-eliciting or regenerating the agent.
- **SC-005**: 100% of re-run outcomes (pass, fail, incomplete) are visible in the UI both live and after the fact.

## Assumptions

- The re-run applies the same standards and scope as the original pipeline checks; it is a fresh examination, not a relaxed one.
- Re-running checks is treated as setup activity (like the original creation-time checks), not as the agent's own runtime spending.
- Fresh verdicts fully replace the agent's previous verdicts; history of the re-run outcome is kept, but gating always uses the latest verdicts.
- Re-runs are user-triggered only; automatic or scheduled re-runs are out of scope.
- Repairing, regenerating, or editing agent code is out of scope — this feature only re-examines what exists.
- The existing approval (consent) flow is unchanged: a green re-run restores eligibility, and the owner still approves deployment where required.
