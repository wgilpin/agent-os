# Quickstart: Conformance Auditor

Generation-independent; runs against the existing hand-written discovery agent. No LLM, no network.

## Run an audit pass on demand (iex)

```elixir
# Compute, persist, and (if a flag is newly raised) alert — for the default agent:
iex> AgentOS.ConformanceAuditor.run_pass()
%AgentOS.ConformanceAuditor.Verdict{agent: "discovery", status: :flagged, flags: [...], ...}

# Pure logic only, against an explicit record list (no persistence, no alert):
iex> records = AgentOS.RunLog.read_records("data/run_log.md", window: 20)
iex> AgentOS.ConformanceAuditor.audit(records, "find interesting accounts", agent: "discovery")
```

## Read the verdict without asking the agent (Principle VIII)

```elixir
# Via the standing inventory (renders the persisted verdict):
iex> IO.puts AgentOS.Inventory.render()
# ... CONFORMANCE: flagged
#       [trust]  gate-breach — manifest-breach attempt recorded in last 20 runs

# Or directly from the store:
iex> AgentOS.StateStore.snapshot("conformance").verdicts["discovery"]
```

## Scheduled operation

`AgentOS.ConformanceAuditor.Scheduler` runs daily (self-rescheduling, mirrors `AgentOS.Scheduler`).
On each pass it persists the verdict and appends one line to `data/admin_alerts.md` for every
newly-raised/escalated flag — never to `data/run_log.md`.

```
$ tail data/admin_alerts.md
- [2026-07-01T07:05:00Z] agent=discovery flag=gate_breach severity=tripwire manifest-breach attempt recorded
```

## What it will and won't do

- **Will**: raise/clear `quiet`, `sick`, `denied_approval` (≥3 human denials in window), `gate_breach`
  (single occurrence) flags; show them in the inventory; alert on newly-raised flags.
- **Won't**: bless an agent, return a pass, gate/approve/block any deploy or action, judge message
  *content* (semantic drift — deferred to 04-05+), or re-flag what the gate enforces per action.

## Test it

```bash
mix test test/agent_os/conformance_auditor_test.exs \
         test/agent_os/conformance_auditor/alert_test.exs
mix test test/agent_os/inventory_test.exs test/agent_os/run_log_test.exs
mix format --check-formatted && mix credo && mix dialyzer
```
