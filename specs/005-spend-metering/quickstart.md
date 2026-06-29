# Quickstart: Spend Metering and Real Kill-on-Breach

How to exercise this feature deterministically — no Docker, no live LLM, no waiting on a real
clock. All examples use the host-command override (`agent_cmd`) and explicit `items`/actions,
the same way the existing `run_supervisor_test.exs` / `run_worker` tests do, plus an injected
`:now`.

## Run the suite

```bash
mix test test/agent_os/spend_ledger_test.exs \
         test/agent_os/run_supervisor_test.exs \
         test/agent_os/inventory_test.exs
```

Full gate + format + Dialyzer before saving (Constitution quality gates):

```bash
mix format && mix credo && mix dialyzer && mix test
```

## Scenario 1 — Windowed cap reaches exactly N, next action blocked (US1)

```elixir
now = ~U[2026-06-29 12:00:00Z]
# manifest cap = 5 (manifests/discovery.md); kv_append cost = 1
# Submit 5 kv_append actions: cumulative spend lands exactly at 5 → all allowed.
RunWorker.run_once(agent_cmd: "echo", items: [...], now: now, manifest_path: ...)
# => :ok ; spend_ledger[agent].spent == 5
# A 6th kv_append in the same run pushes spend to 6 > 5 → breach (see Scenario 2).
```

## Scenario 2 — Over-cap action kills the run via declared on_breach (US1/US2)

```elixir
# Pre-seed ledger so the agent is already at the cap this window.
StateStore.apply_action("spend_ledger", {:put, agent, %{spent: 5, window_start: now}})

RunWorker.run_once(now: now, ...)   # any non-zero-cost action proposed
# => {:killed, :spend_breach}
# - NO action executed (whole batch dropped, FR-012)
# - run log contains: status=killed failure_cause=spend_breach
# - behaviour fired = manifest.spend.on_breach (:kill), by dispatch (SC-003)
```

## Scenario 3 — Window boundary passes, spend resets (US1)

```elixir
yesterday = DateTime.add(now, -25 * 3600, :second)
StateStore.apply_action("spend_ledger", {:put, agent, %{spent: 5, window_start: yesterday}})

RunWorker.run_once(now: now, ...)   # same action that was blocked at the cap
# => :ok  — SpendLedger.current_entry reset spent to 0 and re-anchored window_start to now
#           BEFORE the gate check, so the action is permitted in the new window.
```

## Scenario 4 — Breach kill does not restart; a crash still restarts once (US2)

```elixir
# Breach via supervisor: worker returns {:killed, :spend_breach}
RunSupervisor.start_run(worker_fn: fn _ -> {:killed, :spend_breach} end, run_log_path: log)
# => worker called exactly ONCE; no Alerter; no status=alert line.

# Crash via supervisor: worker returns {:error, _} first, then :ok
# => worker called TWICE (restart-once preserved, FR-007).

# Persistent crash: worker returns {:error, :persistent_failure} both times
# => worker called twice, then status=alert logged (unchanged).
```

## Scenario 5 — Operator sees per-agent spend on the standing inventory (US3)

```elixir
StateStore.apply_action("spend_ledger", {:put, agent, %{spent: 3, window_start: now}})
Inventory.render(manifest_path: ..., now: now)
# => output contains: "SPEND: 3 / 5 per daily"
# After a rollover (window_start 25h ago) the same render shows "SPEND: 0 / 5 per daily".
# Read entirely from the spend_ledger snapshot + manifest — the agent is never contacted.
```

## What to verify maps to which requirement

| Scenario | Requirements | Success Criteria |
|----------|--------------|------------------|
| 1 | FR-001, FR-009, FR-011 | SC-001 |
| 2 | FR-004, FR-005, FR-012 | SC-001, SC-003 |
| 3 | FR-001, FR-002, FR-003, FR-010 | SC-002 |
| 4 | FR-006, FR-007 | SC-004 |
| 5 | FR-008, FR-010 | SC-005 |
| all | FR-010, Constitution IV | SC-006 |
