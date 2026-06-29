# Contract: `AgentOS.Inventory` spend visibility (FR-008)

Edit to `lib/agent_os/inventory.ex`. Adds a per-agent spend line to the standing inventory,
read from the persisted `spend_ledger` store — never from the agent process (Principle VIII).

## Clock injection

- `now = Keyword.get(opts, :now, DateTime.utc_now())` — so a render after a window boundary
  shows the reset (zero) deterministically in tests (FR-010).

## Render addition

Replacing the single `SPEND CAP: #{manifest.spend.cap}` line at `inventory.ex:89`:

```text
spend_ledger = AgentOS.StateStore.snapshot("spend_ledger")
agent_name   = Path.basename(manifest_path, ".md")
raw_entry    = Map.get(spend_ledger, agent_name, %{spent: 0, window_start: now})
entry        = AgentOS.SpendLedger.current_entry(raw_entry, now, manifest.spend.window)
```

Rendered line (current window):

```text
SPEND: <entry.spent> / <manifest.spend.cap> per <manifest.spend.window>
```

- Reports `spent / cap / window` for the **current** window (FR-008): `spent` is the windowed
  value via `SpendLedger.current_entry/3`, so a render after rollover shows `0`.
- **Read-only**: `Inventory` does NOT persist the rollover (display only — research D5);
  enforcement persistence is `RunWorker`'s job. The display value is still correct because it
  applies `current_entry/3` to the snapshot.
- **No agent contact**: the value comes solely from the `spend_ledger` snapshot + the manifest;
  no port, no message to the agent.

## Multi-agent note

The standing inventory renders for the agent identified by `manifest_path` (one manifest per
render, the existing behaviour). "Per agent" is satisfied because `agent_name` keys the lookup;
rendering several agents is just several renders. No change to the single-manifest render model.

## Test contract (`test/agent_os/inventory_test.exs`, deterministic)

1. **Spend shown** — seed `spend_ledger` with `%{<agent> => %{spent: 3, window_start: now}}`;
   `render(manifest_path: ..., now: now)` output contains `SPEND: 3 / <cap> per daily`.
2. **Zero after reset** — seed `spent: 5, window_start: now - 25h`; render with `now` ⇒ output
   shows `SPEND: 0 / <cap> per daily` (windowed reset applied for display).
3. **No entry** — empty `spend_ledger` ⇒ output shows `SPEND: 0 / <cap> per daily`.
4. **No agent contact** — render reads only the store + manifest (no port/agent invocation);
   asserted by the absence of any agent process interaction (consistent with existing inventory
   tests that run without starting the agent).
