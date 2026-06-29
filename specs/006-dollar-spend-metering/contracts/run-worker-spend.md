# Contract: `RunWorker` inference-only breach + combined dollar budget

The changes to `AgentOS.RunWorker.run_once/1` so that inference dollars (metered by the broker into
`spend_ledger` during the run) enforce the cap and a runaway loop is killed even with zero actions.
Reuses 005's kill path and signal; the gate logic is untouched (FR-017).

## Return contract (unchanged shape, broadened trigger)

```elixir
@spec run_once(keyword()) :: :ok | {:killed, :spend_breach} | {:error, any()}
```

`{:killed, :spend_breach}` is now produced by **two** triggers (both via the existing
`dispatch_on_breach(:kill, …)`):
1. **(005, reused)** the gate returns `breached != []` — an action's cost would push `spent` over cap.
2. **(NEW) inference-only breach** — when `run_once` reads `spend_ledger` (after the agent run
   returns, before the gate), the windowed `spent >= cap` already (the broker metered inference past
   the cap *during* the run), so the run is killed and the whole batch dropped **even with zero
   proposed actions** (US2, FR-005).

## Algorithm change (pre-gate inference-only check)

After computing the windowed entry (existing code: `SpendLedger.current_entry`, persist if reset):

```text
spent = agent_entry.spent
cap   = manifest.spend.cap

# NEW — inference-only breach (zero-action runaway). Reuses dispatch_on_breach(:kill,…).
if spent >= cap:
    dispatch_on_breach(:kill, …, breached: [:inference], actions: actions, …)   # ⇒ {:killed, :spend_breach}
else:
    {approved, parked, rejected, breached} = Gate.partition_batch(actions, manifest, registry, %{spent: spent})
    # … existing cond: breached != [] ⇒ dispatch_on_breach; else execute + add per-action dollars …
```

## Combined budget (one ledger, one cap — FR-016)

- `spent` already includes inference dollars written by the broker during the run.
- The existing post-gate increment (`total_approved_cost` summed from the registry, now in
  micro-dollars) adds **per-action dollars** to the **same** `spent` via the same `StateStore`
  single writer.
- The cap is checked against the combined `spent`. No second ledger, no second cap.

## Guarantees

- A run that breaches (either trigger) drops the **whole** batch — no action executes — and returns
  `{:killed, :spend_breach}`; `RunSupervisor` treats it as an intentional stop and does **not**
  restart (005 restart-exemption, reused unchanged) (FR-007).
- A genuine crash/OOM still returns `{:error, _}` and still restarts once (005, unchanged).
- The run-log line for a kill is the existing `status=killed failure_cause=spend_breach`
  (Principle VI); the inference-only trigger logs the same way.

## Test obligations (`run_supervisor_test.exs`, edits)

- **Inference-only breach, zero actions**: seed `spend_ledger[agent].spent >= cap`, run with an
  empty/any action batch ⇒ `{:killed, :spend_breach}`, no actions executed, supervisor does **not**
  restart (SC-002).
- **Combined budget**: seed inference dollars below cap; a run whose action dollars push the combined
  `spent` over cap ⇒ killed against the single cap (FR-016, SC-003).
- **Window reset**: after advancing injected `:now` past the boundary, `spent` resets to 0 and a
  previously-breaching run is permitted (005 semantics, SC-004).
- **Crash still restarts**: a genuine abnormal exit ⇒ `{:error, _}` ⇒ restart-once (unchanged).
