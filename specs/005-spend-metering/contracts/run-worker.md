# Contract: `AgentOS.RunWorker` changes (window reset, on_breach dispatch, kill signal)

Surgical edits to the existing `run_once/1` pipeline at `lib/agent_os/run_worker.ex`. The gate,
connector registry, cost model, and Effector wiring are unchanged (FR-011/013).

## Return type (widened)

```elixir
@spec run_once(keyword()) :: :ok | {:killed, :spend_breach} | {:error, any()}
```

- `:ok` — clean run (actions executed or none proposed).
- `{:killed, :spend_breach}` — NEW. A batch breached the cap and `on_breach` (`:kill`) fired:
  the whole batch was dropped, nothing executed, a `status=killed` line was logged. Intentional
  stop — supervisor MUST NOT restart.
- `{:error, reason}` — fault (timeout, crash, OOM, unexpected stage). Unchanged; supervisor
  retries once.

## Clock injection (FR-010)

- `now = Keyword.get(opts, :now, DateTime.utc_now())`.
- All window-boundary math and any new `window_start` anchor use `now`, never a fresh
  `DateTime.utc_now()` call (so tests are deterministic).

## Window reset, applied before the gate check (FR-001/002/003)

Replacing the current ledger read at `run_worker.ex:160-166`:

```text
spend_ledger = StateStore.snapshot("spend_ledger")
agent_name   = Path.basename(manifest_path, ".md")
raw_entry    = Map.get(spend_ledger, agent_name, %{spent: 0, window_start: now})
entry        = SpendLedger.current_entry(raw_entry, now, manifest.spend.window)

# Persist the reset so the new window is durable + visible (research D5)
if entry != raw_entry do
  StateStore.apply_action("spend_ledger", {:put, agent_name, entry})
end

spent = entry.spent          # feeds Gate.partition_batch(..., %{spent: spent})
```

- The gate is then called with the **windowed** `spent`, so an action blocked late in the prior
  window is permitted again after a rollover.

## on_breach dispatch (FR-004/005/012)

Replacing the hardcoded breach branch at `run_worker.ex:174-196`:

```text
cond do
  breached != [] ->
    dispatch_on_breach(manifest.spend.on_breach, ...)   # drop whole batch, log, signal

  true ->
    # ... existing approved/parked execution + ledger increment (unchanged) ...
end
```

```elixir
# Dispatches on the DECLARED on_breach value — not a hardcoded behaviour (FR-004).
defp dispatch_on_breach(:kill, run_log_path, trigger, items_in, dropped_count, actions, rejected, parked, breached) do
  RunLog.append(%{status: :killed, failure_cause: :spend_breach, ...}, path: run_log_path)  # existing log shape
  {:killed, :spend_breach}
end
```

- `:kill` is the only implemented arm in v2. The whole batch is dropped — `Effector.act_all/1`
  is NOT called and the ledger is NOT incremented (no action executed). This preserves FR-012
  (drop whole batch).
- The dispatch matches the declared field, so the behaviour fired is the manifest's, not a
  constant (FR-004 / SC-003).
- The run-log line retains the existing `status=killed failure_cause=spend_breach` content so
  the kill stays legible in the run-trace.

## `run_and_raise/1` (Task path)

Add a clause so the intentional kill is a normal Task exit (not a crash):

```elixir
case run_once(opts) do
  :ok -> :ok
  {:killed, _reason} -> :ok            # NEW — intentional stop, exit :normal
  {:error, reason} -> raise "RunWorker failed: #{inspect(reason)}"
end
```

## Test contract (`test/agent_os/run_supervisor_test.exs`, deterministic)

Driving `run_once/1` directly (or via `worker_fn`) with `agent_cmd` host override, explicit
`items`/actions, a small `cap`, and an injected `:now`:

1. **Cap boundary** — actions summing to exactly `cap` run (`:ok`, ledger `spent == cap`).
2. **Over-cap kill** — an action pushing spend over `cap` ⇒ `{:killed, :spend_breach}`, no
   action executed, `status=killed failure_cause=spend_breach` in the log.
3. **Reset after rollover** — with ledger `spent == cap` and `window_start` 25 h before `now`,
   the same action that was blocked is now permitted (`:ok`); ledger shows reset window.
4. **No premature reset** — within the window (`now` = start + 1 h), spend keeps accumulating.
