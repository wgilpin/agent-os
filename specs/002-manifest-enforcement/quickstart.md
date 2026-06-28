# Quickstart: Manifest Enforcement (v2)

Prerequisites: Phase 1/2 working (Elixir ~> 1.20, Docker available, the discovery agent image
built per Phase 2 — `scripts/agent_image.sh`).

## 1. Build / refresh the agent images

```bash
# the normal stub agent (Phase 2)
scripts/agent_image.sh

# the adversarial stub used by the world-B test (built by the same script or tagged separately)
# emits an out-of-scope recipient, an over-cap action, and an ungranted method
```

## 2. Run the unit suites (deterministic, no Docker)

```bash
mix test test/agent_os/gate_test.exs \
         test/agent_os/spend_meter_test.exs \
         test/agent_os/credential_proxy_test.exs \
         test/agent_os/manifest_test.exs \
         test/agent_os/trigger_bus_test.exs \
         test/agent_os/effector_test.exs
```

These cover: gate decision order incl. every reject branch (world-B unit proof), fixed-window
spend with cap-boundary + reset, credential injection with the secret absent from agent inputs,
manifest constraints parsing + loud failure on a malformed manifest, event/message triggers
firing exactly one run, approval park-and-resume, and the effector executing only gate-approved
actions.

## 3. Drive a gated run end to end

```bash
iex -S mix
# fire the daily-style run manually
iex> AgentOS.Scheduler.run_now(:manual)
# inspect the legible trace — gate decisions, executed actions, spend
iex> File.read!("data/run_log.md") |> IO.puts()
```

## 4. Fire event- and message-triggers

```elixir
iex> AgentOS.TriggerBus.message(%{"note" => "operator nudge"})   # one run, trigger: :message
iex> AgentOS.TriggerBus.event("refresh", %{})                    # one run, trigger: :event
```

## 5. Drive an approval (park-and-resume)

```elixir
# a run proposes a requires_approval action → it parks, the run completes
iex> AgentOS.Scheduler.run_now(:manual)
# the action is pending; nothing executed it yet. Approve it:
iex> AgentOS.TriggerBus.event({:approval, ref}, %{})             # ref from the run-log / pending list
# now the parked action runs through the gate + effector
```

## 6. Trip a spend breach (real kill, no restart)

```elixir
# with spend.cap small and per-action costs, a run that exceeds the cap is killed
iex> AgentOS.Scheduler.run_now(:manual)
# run_log shows killed: :spend_breach; RunSupervisor does NOT retry/alert (intentional stop)
```

## 7. World B — the adversarial proof (Docker)

```bash
mix test test/agent_os/world_b_test.exs --only docker
```

Asserts the adversarial stub agent is blocked in all three categories — out-of-scope recipient,
over-cap spend, ungranted method — with the effector never executing any of them.

## What "v2 done" looks like

- Every proposed action passes through the gate before any effector execution (SC-001).
- Out-of-scope recipient / method / connector are all rejected (SC-002).
- The manifest's grants/caps/constraints appear in neither the boundary payload nor the mount
  set; no mutating credential reaches the agent (SC-003/SC-004).
- A spend breach kills the run and does not restart; a genuine crash still restart-once-alerts
  (SC-005/SC-006).
- Event/message triggers and approval-as-event work (SC-007).
- The adversarial agent is physically blocked — world B (SC-008).
