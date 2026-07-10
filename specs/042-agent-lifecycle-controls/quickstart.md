# Quickstart & Manual Verification: Agent Lifecycle Controls

## Run the tests (automated backend coverage)

```bash
mix test test/agent_os/deployment_registry_test.exs \
         test/agent_os/trigger_arming_test.exs \
         test/agent_os/agent_lifecycle_test.exs
mix test            # full suite must stay green
mix compile --warnings-as-errors
```

Automated tests cover: `mark_active`/`delete` registry round-trips; `disarm`/`rearm` timer
cancellation (including retype-away-from-time) and the stale-fire guard; `AgentLifecycle`
pause/resume/delete (files + state + pending approvals on temp dirs), spend-cap validation, and
full trigger editing (per-type round-trip, add/remove/retype, atomic validation, dedupe, empty
list, startup-not-fired-on-edit).

## Manual walkthrough (UI — Constitution III: manual, not unit-tested)

Start the server and open `/inventory` with at least one deployed agent.

1. **Pause / Resume**
   - Click **Pause** on a deployed-active agent → badge flips to a distinct **Paused** state.
   - Confirm dispatch is refused while paused (e.g. test-fire a message trigger → rejected).
   - Click **Resume** → badge returns to active; `deployed_at`/provenance unchanged; scheduled times
     re-arm; the startup trigger does **not** fire.
   - Restart the app while paused → the agent stays paused, no startup fire.

2. **Edit spend cap**
   - Open the agent's edit panel, set the cap to `$2`, submit → manifest frontmatter shows
     `cap: 2000000`; the next spend evaluation enforces $2; already-accumulated spend is unchanged.
   - Enter `0`, a negative, or non-numeric → on-page error, manifest unchanged.

3. **Edit triggers**
   - Change a daily time trigger to ~2 minutes ahead, submit → the agent fires once at the new time
     and never again at the old time (including if the old time was already armed).
   - **Trigger-type conversion**: take a startup-only (or trigger-less) agent, use **Add trigger** to
     add a daily time ~2 minutes ahead, save → it fires once at that time; the startup trigger did
     NOT fire on the edit. Then **Remove** the time trigger and save → silence (no further fires).
   - Retype a time trigger to **On a message** and save → the old time stops firing and (for a
     deployed-active agent) the test-fire form appears on the card.
   - Enter an invalid time (e.g. `25:00`), a blank event name, or two identical triggers → on-page
     error, triggers unchanged (atomic).
   - Remove every trigger and save → succeeds; the panel notes the agent will never run until a
     trigger is added back.

4. **Delete**
   - Click **Delete** → browser `data-confirm` names the consequences (code, manifest, runtime state
     removed permanently). Cancel → nothing happens.
   - Confirm → row disappears; `agents/<name>/` and `manifests/<name>.md` are gone; per-agent state
     (deployment record, spend ledger, provenance, conformance, judge, security-review, pending
     approvals) is gone; `data/run_log.md` history is preserved.
   - Restart the app → no boot warnings reference the deleted agent.

5. **Multi-session refresh**
   - Open `/inventory` in two tabs; perform an action in one → the other reflects it without a manual
     reload.

6. **Run now**
   - On a deployed-active agent, click **Run now** → "Run started" note appears and a run with
     trigger `manual` shows under recent executions shortly (spend cap and grants apply as normal).
   - Pause the agent → the Run now button disappears with the other active-only controls.

7. **System agents hidden**
   - `discovery` (config `:system_agents`) does not appear on `/inventory` at all; it keeps running
     on its own schedule.

## Notes

- All mutations flow through `AgentOS.AgentLifecycle`; the LiveView holds no business logic.
- Do not run the Phoenix server as part of automated CI for this feature; the walkthrough above is
  the acceptance check for the UI surface.
