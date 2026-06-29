# Quickstart: Event-, Message-, and Approval-as-Event Triggers

Exercises the three slices against the existing discovery agent. All examples are substrate-side (IEx /
ExUnit) — that is the point: the **substrate** fires agents and releases held actions; the agent never can.
Everything here runs deterministically with injected functions; no network, no LLM, no Docker.

## Prerequisites

- The discovery manifest already declares a `message` trigger and (for these examples) add an `event`
  trigger named `bookmark_saved`:

  ```yaml
  triggers:
    - type: time
      at: "07:00"
    - type: message
    - type: event
      name: bookmark_saved
  ```

- `external_send` is already `requires_approval?: true`, so any `external_send` the agent proposes is parked
  — no manifest change needed to demo approval.

## 1. Event-trigger fires a run (US1)

```elixir
# A bookmark-saved event arrives at the substrate with a payload.
TriggerGateway.submit_sync({:event, "bookmark_saved", %{"url" => "https://example.com/post"}})
#=> {:fired, ["discovery"]}     # exactly one run; payload delivered as run input

# An event no agent declares fires nothing (default-deny).
TriggerGateway.submit_sync({:event, "unknown_event", %{}})
#=> {:fired, []}

# Verify provenance without asking the agent:
#   data/run_log.md contains a line with  trigger=event:bookmark_saved
Inventory.render() # Last Run Trigger: event:bookmark_saved
```

## 2. Message-trigger wakes the agent — operator is just another process (US2)

```elixir
# The operator (a substrate-side caller, not a privileged path) messages the agent.
TriggerGateway.submit_sync({:message, "discovery", "look at the new saves"})
#=> {:fired, ["discovery"]}     # run fires; message delivered as run input; trigger=message

# A message to an agent with no message trigger is refused.
TriggerGateway.submit_sync({:message, "no_msg_agent", "hi"})
#=> {:rejected, :no_message_trigger}
```

## 3. Approval of a held action is an event-trigger (US3)

```elixir
# A normal run proposes an external_send → the gate parks it (requires_approval? = true).
# Nothing is sent. The held action is visible WITHOUT asking the agent:
Inventory.render()
#=> ... Pending approvals:
#=>   ref_42  external_send → owner-inbox

# It does NOT execute on its own. Now the human approves exactly that ref:
TriggerGateway.submit_sync({:approval, :approve, "ref_42"})
#=> {:resolved, :approved}      # exactly that external_send executes at the chokepoint; ref removed
#   run_log line: trigger=approval-resume ref=ref_42

# Approving the same ref again does nothing (at-most-once):
TriggerGateway.submit_sync({:approval, :approve, "ref_42"})
#=> {:resolved, :unknown_ref}

# Denial drops a held action without executing it:
TriggerGateway.submit_sync({:approval, :deny, "ref_99"})
#=> {:resolved, :denied}        # ref_99 removed; nothing sent
```

## 4. The trust boundary holds

- There is **no** API the sandboxed agent can call to submit a signal — `TriggerGateway` is a substrate
  GenServer reachable only from inside the control plane. An event name, message, or ref appearing in the
  agent's stdout or in untrusted web input it read **cannot** become a fire or release a held action
  (FR-009, FR-010).
- Every fire is attributable from `data/run_log.md` alone; every held action is listed on the inventory
  before it resolves (Principle VIII).
- Event/message-fired runs pass through the gate, credential proxy, and spend metering exactly like the
  timer-fired run — no path bypasses enforcement (FR-015).

## Run the tests

```bash
mix test test/agent_os/trigger_gateway_test.exs \
         test/agent_os/run_log_test.exs \
         test/agent_os/inventory_test.exs
mix format --check-formatted && mix credo
```
