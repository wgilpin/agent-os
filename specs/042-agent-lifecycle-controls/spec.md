# Feature Specification: Agent Lifecycle Controls

**Feature Branch**: `042-agent-lifecycle-controls`
**Created**: 2026-07-09
**Status**: Draft
**Input**: User description: "Add per-agent lifecycle controls to the /inventory page: pause, resume, delete, and editing of schedule and spend cap."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Pause and resume an agent (Priority: P1)

As the owner, I can pause any deployed agent from the inventory page so that it stops acting entirely — no scheduled run, incoming event, message, or startup can trigger it — and later resume it, restoring exactly the behavior it had before, without redeploying or losing any of its history or configuration.

**Why this priority**: The kill-switch is the core safety affordance. An agent misbehaving (spamming a channel, burning spend) must be stoppable in one click, reversibly — today the only options are letting it run or manual filesystem surgery.

**Independent Test**: Pause a deployed agent, submit a message trigger to it and confirm it is refused; restart the system and confirm it stays paused; resume it and confirm triggers dispatch again.

**Acceptance Scenarios**:

1. **Given** a deployed, active agent, **When** the owner clicks Pause, **Then** the inventory shows it as Paused and every trigger path (time, event, message, startup) refuses to fire it.
2. **Given** a paused agent, **When** the system restarts, **Then** the agent remains paused and its startup trigger does not fire.
3. **Given** a paused agent, **When** the owner clicks Resume, **Then** its deployment status returns to active with its original deployment date and provenance intact, its scheduled times fire again, and its startup trigger does NOT fire (resume is not a redeploy).
4. **Given** a paused agent, **When** viewing the inventory, **Then** its Paused state is visually distinct from an agent that was never deployed.

---

### User Story 2 - Delete an agent completely (Priority: P2)

As the owner, I can permanently delete an agent from the inventory page. After an explicit confirmation, the agent disappears from the inventory and everything that belongs to it is removed: its manifest, its generated code, its deployment record, and its per-agent runtime state (spend ledger, provenance, conformance, judge and security-review results, and any of its pending approvals).

**Why this priority**: Generated agents accumulate (the working tree already carries several near-duplicate experiments). Without delete, retired agents clutter the inventory and keep stale state forever.

**Independent Test**: Delete a scratch agent and verify its inventory row, files, and stored state are all gone; restart the system and confirm no warnings reference the deleted agent.

**Acceptance Scenarios**:

1. **Given** any agent in the inventory, **When** the owner clicks Delete, **Then** a confirmation states that the agent's code, manifest, and runtime state will be removed permanently, and nothing happens unless confirmed.
2. **Given** a confirmed delete, **When** it completes, **Then** the agent no longer appears in the inventory, its manifest file and code directory are gone, and no per-agent state (deployment record, spend ledger, provenance, conformance, judge results, security-review results, pending approvals) remains.
3. **Given** a deleted agent that had scheduled or armed triggers, **When** those times arrive, **Then** nothing fires and no errors are logged against the deleted agent, including after a restart.
4. **Given** a delete issued while one of the agent's runs is in flight, **Then** the in-flight run finishes on its own (short-lived) but no future run can start from the moment the delete is accepted.
5. **Given** a completed delete, **Then** the global run history is preserved unchanged (the deleted agent's past runs remain in the log).

---

### User Story 3 - Edit an agent's spend cap (Priority: P3)

As the owner, I can change any agent's daily spend cap from the inventory page by entering a dollar amount. The new cap takes effect from the next action the agent attempts, with no restart or redeploy.

**Why this priority**: Spend caps are set once at elicitation and are otherwise immutable; tuning an over- or under-provisioned agent currently requires hand-editing files.

**Independent Test**: Set an agent's cap to a new dollar value, confirm the stored configuration reflects it exactly, and confirm the spend gate enforces the new value on the agent's next run.

**Acceptance Scenarios**:

1. **Given** an agent with a $1 daily cap, **When** the owner sets the cap to $2, **Then** the agent's stored configuration shows the new cap and the next spend evaluation enforces $2.
2. **Given** the edit form, **When** the owner enters zero, a negative number, or a non-number, **Then** the change is rejected with a clear error and the existing cap is untouched.
3. **Given** a cap edit, **Then** the agent's spend already accumulated in the current window is preserved (editing the cap does not reset what was spent).

---

### User Story 4 - Edit an agent's triggers (Priority: P3)

As the owner, I can fully edit any agent's triggers from the inventory page: add a trigger, remove one, or change one's type (daily time, startup, event, message) and its parameters. Changes take effect immediately: a removed or retyped daily time stops firing and a newly added time fires, without a restart.

**Why this priority**: Triggers are fixed at elicitation; in practice many generated agents end up with no triggers (or startup-only), leaving them impossible to reschedule or convert without hand-editing files and rebooting.

**Independent Test**: Convert a startup-only agent to a daily time a couple of minutes ahead, observe exactly one run at the new time; then remove the trigger and observe silence.

**Acceptance Scenarios**:

1. **Given** an agent with a daily trigger at 09:00, **When** the owner changes it to 10:00, **Then** the agent fires at 10:00 and never again at 09:00 — including the case where the 09:00 timer was already armed before the edit.
2. **Given** an agent with only a startup trigger (or none at all), **When** the owner adds a daily time trigger, **Then** it arms and fires at that time without a restart.
3. **Given** an agent with a daily time trigger, **When** the owner retypes it to a message trigger (or removes it), **Then** the old time never fires again and, for a deployed-active agent, the message test-fire affordance appears.
4. **Given** the edit form, **When** the owner submits an invalid entry (bad HH:MM, blank event name, unknown type, or two identical triggers), **Then** the whole edit is rejected with a clear error and the existing triggers are untouched (atomic).
5. **Given** an edit that adds or keeps a startup trigger, **Then** the startup trigger does NOT fire on the edit itself — startup fires only at deploy completion and at boot.
6. **Given** the owner removes every trigger, **Then** the edit succeeds and the agent simply never runs until triggers are added back (inert, not an error).

---

### Edge Cases

- Pause/resume/delete on an agent whose inventory row exists (manifest present) but which was never deployed: pause and resume are meaningless (no deployment record) and must fail gracefully with a clear message; delete must still work and remove files and any state.
- Resume on an agent whose manifest file has gone missing while paused: resume must fail loudly rather than reactivate an unrunnable agent.
- Two browser sessions open on the inventory: an action in one session is reflected in the other without a manual reload.
- A trigger edit racing an already-in-flight fire of a removed/retyped time: at most one stale fire may already be executing, but the old time must never fire again after the edit completes.
- Removing all triggers then re-adding one later: both edits succeed; the agent is silent in between and resumes normally after.
- Delete of an agent whose files are partially missing (e.g. code directory already removed by hand): delete completes the cleanup rather than erroring.
- Concurrent identical actions (double-click on Pause/Delete): the second action is a harmless no-op, never an error page.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The inventory page MUST offer per-agent actions: Pause (deployed & active agents), Resume (paused agents), Delete (all agents), and an edit form for spend cap and existing daily trigger times.
- **FR-002**: Pausing an agent MUST prevent every trigger path — scheduled time, event, message, and startup — from starting a run, MUST survive a system restart, and MUST NOT alter the agent's manifest, code, spend history, or deployment provenance.
- **FR-003**: The inventory MUST display three distinct deployment states: active, paused (previously deployed, currently inactive), and never-deployed.
- **FR-004**: Resuming a paused agent MUST restore trigger dispatch (including re-arming its scheduled times) while preserving the original deployment timestamp and provenance, and MUST NOT fire its startup trigger.
- **FR-005**: Delete MUST require an explicit confirmation that names the consequences (code, manifest, and runtime state removed permanently).
- **FR-006**: A confirmed delete MUST remove: the agent's manifest file, its generated code directory, its deployment record, and its per-agent entries in the spend ledger, provenance, conformance, judge-results, and security-review stores, plus any pending approvals belonging to it.
- **FR-007**: Delete MUST gate future dispatch before removing files/state (no run may start after the delete is accepted), MUST cancel any armed timers for the agent, and MUST NOT cancel an already-running ephemeral run.
- **FR-008**: Delete MUST NOT erase global history (the shared run log is preserved).
- **FR-009**: Spend-cap edits MUST accept a positive dollar amount, persist it to the agent's manifest (stored in micro-dollars), reject zero/negative/non-numeric input without side effects, and take effect on the agent's next spend evaluation without restart. Accumulated spend in the current window is preserved.
- **FR-010**: Trigger edits MUST support the full trigger list — adding, removing, and retyping triggers among exactly the types `startup`, `time` (valid HH:MM 00:00–23:59), `event` (non-empty name), and `message` — persist to the manifest, and take effect without restart: a removed or retyped time MUST stop firing (even if already armed) and a newly added time MUST fire daily. Validation is atomic: any invalid entry or duplicate trigger rejects the whole edit without side effects — except rows the owner added but never filled in (blank time/event fields), which are silently dropped on save rather than blocking it. An empty trigger list is a valid outcome (the agent becomes inert). Editing MUST NOT fire a startup trigger — startup fires only at deploy completion and at boot.
- **FR-011**: All lifecycle mutations MUST flow through a single substrate-side lifecycle seam (one module the UI calls), keeping the web layer free of direct registry/filesystem/manifest writes; deployment-record writes remain exclusively inside the deployment registry (Constitution IX single-writer).
- **FR-012**: Every action MUST surface its outcome in the UI: success refreshes the agent's row in place; failure shows a human-readable error and changes nothing. Other open inventory sessions MUST reflect the change without manual reload.
- **FR-013**: Actions targeting an agent in an incompatible state (pause when never deployed, resume when manifest missing, double-submitted delete) MUST fail or no-op gracefully with a clear message — never a crash or an inconsistent partial state.
- **FR-014**: The owner MUST be able to start one run of a deployed-active agent immediately ("Run now"), regardless of its declared trigger types, through the same deployed-and-active gate, spend cap, and grants as any triggered run. Paused, undeployed, and substrate-owned agents are refused; the UI confirms the run started (the run itself is asynchronous).

### Key Entities

- **Deployment record**: per-agent runtime deployment state (name, manifest path, deployed-at, provenance, active flag). Pause/resume flip the active flag in place; delete removes the record. Its absence means never-deployed.
- **Manifest**: the agent's authority document (purpose, grants, triggers, spend cap). Trigger and cap edits rewrite it; it remains the single source of truth read at enforcement time.
- **Trigger**: one entry in the manifest's trigger list — `startup`, daily `time` (HH:MM), `event` (named), or `message`. Fully editable as a list (add/remove/retype); duplicates are rejected.
- **Armed timer**: the in-memory scheduled next-occurrence of a daily trigger. Must become cancellable and re-armable per agent for edits and deletes to take effect without restart.
- **Per-agent runtime state**: spend ledger, provenance, conformance, judge results, security-review results, pending approvals — all keyed by agent name and all removed on delete.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An owner can stop a misbehaving agent in a single confirmed click, and no run of that agent starts afterward (0 post-pause dispatches across all trigger types, verified across a restart).
- **SC-002**: A resumed agent's next scheduled occurrence fires within one minute of its declared time, and its deployment metadata is byte-identical to before the pause (except the active flag).
- **SC-003**: After deleting an agent, 100% of its per-agent artifacts (2 filesystem locations, 6+ state entries) are gone, and a subsequent system restart logs zero warnings referencing it.
- **SC-004**: A trigger change takes effect without restart: a removed/retyped time produces zero fires after the edit and a newly added time fires on its next occurrence.
- **SC-005**: A spend-cap change is enforced on the agent's very next spend evaluation (no runs execute under the old cap after the edit completes).
- **SC-006**: All invalid inputs (bad time, non-positive cap) are rejected with an on-page error and zero persisted changes.

## Assumptions

- Single-owner deployment: anyone with access to the inventory page is the owner; no per-action authorization is needed beyond the existing page access.
- A browser-native confirmation dialog is sufficient for delete (no custom modal component exists in this codebase, and building one is not part of this feature).
- Pause is represented by the existing deployment-record active flag; "paused" and "marked inactive at boot due to a missing manifest" are the same state and that is acceptable.
- Trigger editing covers the full list — add, remove, and retype among `startup`/`time`/`event`/`message` with their parameters. Non-daily time cadences remain out of scope (time triggers are daily).
- Manifest rewrite fidelity is acceptable for generated agents: manifests on disk are exactly the serializer's output today, so a load→modify→write round-trip loses nothing.
- In-flight runs are short-lived subprocesses; there is no requirement to cancel them mid-run on pause or delete.
- Substrate-owned agents (config `:agent_os, :system_agents`, currently `discovery`) are not the user's to manage: the inventory hides them and every lifecycle mutation refuses them (`{:error, :system_agent}`). Their manifests may carry fields the serializer does not round-trip (mounts), and their files can be tracked test fixtures.
- Out of scope: editing grants/capabilities, purging run-log history, the legacy global discovery scheduler, and undo/restore of deleted agents.
