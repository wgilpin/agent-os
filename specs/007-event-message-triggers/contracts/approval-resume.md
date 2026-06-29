# Contract: Approval-Resume (approval modelled as an event-trigger)

Releasing a gate-**parked** action on a human approval. Reuses the existing `pending_approvals` store
(written by `RunWorker`) and the existing post-gate chokepoint `Effector.act/1`. No new store; no LLM in
the release path.

## Trigger

An admitted approval signal handled by `TriggerGateway`:

```elixir
{:approval, :approve | :deny, ref :: String.t()}
```

## Behaviour

```text
snapshot = StateStore.snapshot("pending_approvals")
case Map.get(snapshot.approvals, ref) do
  nil ->
    log "approval for unknown ref <ref> — no-op"
    {:resolved, :unknown_ref}

  %{action: action, grant: grant} = entry ->
    # 1. REMOVE FIRST (single-writer StateStore) — makes execution at-most-once.
    StateStore.apply_action("pending_approvals", {:remove_approval, ref})
    case decision do
      :approve ->
        effector_fn.(%{action: action, grant: grant})   # the SAME post-gate chokepoint
        RunLog.append(%{status: :ok, trigger: "approval-resume", ref: ref, ...})
        {:resolved, :approved}
      :deny ->
        RunLog.append(%{status: :ok, trigger: "approval-resume", ref: ref, note: "denied", ...})
        {:resolved, :denied}
    end
end
```

(`{:remove_approval, ref}` is a thin add to the `pending_approvals` store's `apply_action/2` reducer,
alongside the existing `{:put, :approvals, _}` it already handles.)

## Guarantees

- **Exactly that action**: only the `%{action, grant}` stored under `ref` is executed — never another
  (FR-007, US3 scenario 2/4).
- **At-most-once**: removal precedes `effector_fn`; a duplicate `:approve` for the same `ref` finds `nil`
  and executes nothing further (FR-013, US3 edge: duplicate approvals).
- **Deny drops without executing** (FR-008, US3 scenario 3).
- **Unknown ref is a logged no-op** (FR — edge: unknown ref) — including the case where the agent emits a
  ref it invented; it never matches a real held action it didn't legitimately produce, and even a real ref
  cannot be approved *by the agent* because the agent has no path to this API (FR-009, US3 scenario 5).
- **Gate stays the firewall**: the action was already classified `needs_approval` by the gate; resume
  re-dispatches it through `Effector.act/1` (which holds the credential via `CredentialProxy`), with no LLM
  involved (Principle XI).
- **Persistence across runs**: the entry survives the originating run's end; a later approval still executes
  it (FR-014).

## Legibility

- The pending entry is visible on the standing inventory (ref + short action summary) before it resolves
  (FR-012, Principle VIII).
- The resolution is recorded in the run-log with `trigger=approval-resume` and the `ref` (FR-011).

## Test contract (`trigger_gateway_test.exs`, approval cases)

- parked `ref` + `:approve` → `effector_fn` called exactly once with the stored `%{action, grant}`; entry
  removed; `{:resolved, :approved}`.
- same `ref` approved twice → `effector_fn` called exactly once total; second → `{:resolved, :unknown_ref}`.
- parked `ref` + `:deny` → `effector_fn` not called; entry removed; `{:resolved, :denied}`.
- unknown `ref` → `effector_fn` not called; `{:resolved, :unknown_ref}`; logged.
- a held action remains unexecuted until an approval arrives (no execution on park).
