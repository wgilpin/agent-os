# Contract: Triggers & Approval (in-BEAM)

Beyond the Phase 1 daily timer, runs can be fired by an event-trigger or a message-trigger,
delivered as in-BEAM messages to `AgentOS.TriggerBus` (no external network surface this phase —
FR-014). Approval is modelled as an event-trigger with park-and-resume semantics (FR-015).

## Trigger bus interface

```elixir
# Fire a run from an event (approval is a reserved event name).
@spec event(name :: term(), payload :: map()) :: :ok      # GenServer.cast

# Fire a run from a message (operator-via-chat is just a message).
@spec message(payload :: map()) :: :ok                    # GenServer.cast
```

Both route through the existing `RunSupervisor.start_run/1`, tagging the run-log with
`trigger: :event | :message` (the daily `Scheduler` continues to tag `:timer`). Each trigger
fires **exactly one** run (SC-007).

## Approval = event-trigger (park-and-resume)

```text
run N:   agent proposes action A on a requires_approval connector
         → gate returns {:needs_approval, grant}
         → substrate writes PendingApproval{ref, action: A, grant} to StateStore
         → run N completes and reaches its terminal state (NO blocked process)

later:   TriggerBus.event({:approval, ref}, %{})
         → substrate loads PendingApproval{ref}
         → re-runs A through the gate (now without the approval gate) + effector
         → on success, removes the PendingApproval and logs the execution
```

### Guarantees

- An action awaiting approval does **not** execute until the matching approval event arrives
  (FR-015, SC-007).
- No process blocks waiting on a human — the run completes and the action stays pending
  (Constitution IX; resolves the "approval never arrives" edge case — the run is terminal and
  the action simply remains pending).
- The approval event is correlated by `ref`; an approval for an unknown/expired `ref` is logged
  and ignored (loud, no side effect).
- The resumed action is re-validated by the gate (recipient/method/spend still enforced at
  execution) — approval grants permission to proceed, never a bypass of the rest of the envelope.

## Trigger declaration

Triggers are declared in the manifest `triggers:` list (see
[manifest-schema.md](./manifest-schema.md)). The bus only honors trigger types the manifest
declares; an event/message for an undeclared trigger type is logged and ignored.
