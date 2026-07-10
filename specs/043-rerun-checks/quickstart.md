# Quickstart: Re-run Checks (manual verification)

Prereqs: `mix deps.get`; run from repo root. Tests: `mix test` (must end fully green).

## Automated verification

```bash
# Core re-run behaviour: pass/fail/incomplete, staleness, spend-cap lift, no-deploy, refusals
mix test test/agent_os/pipeline/rerun_test.exs

# One-run-per-agent lock
mix test test/agent_os/pipeline/run_lock_test.exs

# UI: button visibility + click; consent gate-refusal remedy copy
mix test test/agent_os_web/inventory_live_test.exs test/agent_os_web/consent_live_test.exs

# Full suite (regression)
mix test
```

## Manual walkthrough

1. **Strand an agent**: create an agent through the elicitation → pipeline flow, then remove
   its verdicts (e.g. delete rows from `judge_results`/`security_review_results`, or use an
   agent whose checks never recorded). Open `/inventory`: the card shows "Code check: not run
   yet" / "Safety check: not run yet" and Approval "Waiting for your approval".
2. **Refusal points to the remedy (US3)**: open `/consent?manifest=manifests/<name>.md` and
   click **Approve**. The gate refuses with a message naming the reason and a **Re-run its
   checks from the inventory** link. For an orphan (no `agents/<name>/main.py`), the message
   instead says re-create or delete.
3. **Re-run (US1)**: back on `/inventory`, click **Re-run checks** on the card. The judge and
   safety badges update live (no refresh) as each check runs, then settle on pass/pass. A
   "Last checks re-run: passed" line appears. The agent is now approvable — approve it on the
   consent page and it deploys/runs through the normal flow. Nothing was waived.
4. **Failed re-run stays blocked (US2)**: on an agent whose code violates its manifest, click
   **Re-run checks**. The safety badge settles on "fail", the card shows the failing check and
   reason, and the agent remains blocked (approve still refuses).
5. **One at a time (FR-009)**: click **Re-run checks** twice quickly — the second click shows
   "a check is already running for this agent — wait for it to finish".
6. **System agents / orphans (FR-008)**: system agents are hidden from inventory (no button);
   an orphan card (manifest, no code) shows no **Re-run checks** button.

## What to confirm

- A green re-run opens `Provisioner.deploy_gate/3` (agent becomes approvable) — recovery goes
  *through* the checks.
- A red/incomplete re-run never opens the gate (SC-002).
- The re-run never deploys, approves, or runs the agent itself (FR-004).
- Re-run cost is the two checks only — no re-elicitation, no regeneration (SC-004).
- The agent's runtime spend cap does not block the re-run (setup activity).
