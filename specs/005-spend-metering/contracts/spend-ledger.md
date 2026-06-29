# Contract: `AgentOS.SpendLedger` (pure window helper)

New module. Pure functions only — no process, no I/O, no clock side-effect. Defines the
windowed-entry semantics shared by `RunWorker` (enforcement) and `Inventory` (display).

```elixir
@type entry :: %{spent: number(), window_start: DateTime.t()}
@type window :: :daily
```

## `duration_seconds/1`

```elixir
@spec duration_seconds(window()) :: pos_integer()
def duration_seconds(:daily), do: 86_400
```

- Total seconds in a fixed window. `:daily` ⇒ `86_400`.
- Matches `:daily` explicitly; any other value is unsupported in v2 (function clause error —
  loud failure, not a silent default). v2 only ever constructs manifests with `window: :daily`.

## `rolled_over?/3`

```elixir
@spec rolled_over?(DateTime.t(), DateTime.t(), window()) :: boolean()
def rolled_over?(window_start, now, window)
```

- Returns `true` when `now` is at-or-after `window_start + duration_seconds(window)` seconds.
- Implemented as `DateTime.compare(now, DateTime.add(window_start, duration_seconds(window), :second)) != :lt`.
- Boundary is inclusive of the reset moment: exactly at the boundary ⇒ rolled over (`true`).

## `current_entry/3`

```elixir
@spec current_entry(entry(), DateTime.t(), window()) :: entry()
def current_entry(entry, now, window)
```

- If `rolled_over?(entry.window_start, now, window)` ⇒ returns `%{spent: 0, window_start: now}`.
- Otherwise ⇒ returns `entry` unchanged.
- Idempotent within a window; one call zeroes spend regardless of how many boundaries elapsed
  (handles the "repeated resets / idle for days" edge case).

## Caller obligations

- **Default entry**: callers reading the `spend_ledger` snapshot for an agent with no entry yet
  MUST default to `%{spent: 0, window_start: now}` before calling `current_entry/3` (or
  equivalently treat a missing entry as already-current with spent 0).
- **Persistence**: `current_entry/3` does NOT persist. `RunWorker` MUST persist a changed
  (rolled-over) entry via `StateStore.apply_action("spend_ledger", {:put, agent_name, entry})`.
  `Inventory` MUST NOT persist (read-only display).

## Test contract (`test/agent_os/spend_ledger_test.exs`, pure)

1. `duration_seconds(:daily) == 86_400`.
2. `rolled_over?` is `false` strictly within the window (e.g. now = start + 1 h).
3. `rolled_over?` is `true` exactly at the boundary (now = start + 24 h) and beyond.
4. `current_entry` returns the entry unchanged within the window (spend preserved).
5. `current_entry` returns `%{spent: 0, window_start: now}` at/after the boundary.
6. `current_entry` zeroes spend when several windows elapsed (now = start + 3 days).
