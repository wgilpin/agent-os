# Phase 1 Data Model: Conformance Auditor

All types are Elixir structs with `@type` typespecs (Principle V). No bare maps cross a module
boundary. Everything is derived from the run-log; nothing is read from the agent.

## RunRecord — `AgentOS.ConformanceAuditor.RunRecord`

One parsed run-log line. Produced by `AgentOS.RunLog.read_records/2`.

| Field | Type | Source | Notes |
|---|---|---|---|
| `status` | `String.t()` | `status=` | e.g. `"ok"`, `"alert"` |
| `actions` | `non_neg_integer()` | `actions=` | |
| `trigger` | `String.t() \| nil` | `trigger=` | e.g. `"timer"`, `"manual"`, `"approval-resume"` |
| `items_in` | `non_neg_integer()` | `items_in=` | default 0 |
| `items_dropped` | `non_neg_integer()` | `items_dropped=` | default 0 |
| `rejected_count` | `non_neg_integer()` | `rejected_count=` | gate constraint rejections — **not** used by Leg 2a |
| `parked_count` | `non_neg_integer()` | `parked_count=` | |
| `breached_count` | `non_neg_integer()` | `breached_count=` | Leg 2b |
| `gate_reasons` | `[String.t()]` | `gate_reasons=` | Leg 2b (non-empty ⇒ breach) |
| `note` | `String.t()` | trailing note | Leg 2a reads `"denied"` here on approval-resume records |

Validation / parsing rules:
- Only lines containing `status=` are records; `digest:` lines are excluded.
- A line that fails to parse is skipped with a `Logger.warning` (Principle VI), never silently dropped.
- Numeric fields absent ⇒ 0; `gate_reasons` absent ⇒ `[]`.

## Flag — `AgentOS.ConformanceAuditor.Flag`

A single raised signal.

```text
@enforce_keys [:type, :severity, :description]
type:        :quiet | :sick | :denied_approval | :gate_breach
severity:    :health | :tripwire | :count
description: String.t()   # human-readable, e.g. "No action in 3 consecutive runs"
```

| Flag type | Leg | Severity | Raise condition (within window) |
|---|---|---|---|
| `:quiet` | 1 | `:health` | trailing `actions=0` streak ≥ 3 |
| `:sick` | 1 | `:health` | any `status="alert"` in window; or latest record `items_dropped > 0` **and** its `items_dropped/items_in` share strictly exceeds the previous record's |
| `:denied_approval` | 2a | `:count` | ≥ 3 `approval-resume` records noted `denied` |
| `:gate_breach` | 2b | `:tripwire` | any `breached_count > 0` or `gate_reasons ≠ []` |

Severity ordering for escalation comparison (FR-013): `:health` < `:count` < `:tripwire`.

## Verdict — `AgentOS.ConformanceAuditor.Verdict`

The auditor's output for one agent. Computed by `audit/2`, persisted by `run_pass/1`, rendered by
the inventory.

```text
@enforce_keys [:agent, :status, :flags, :computed_at]
agent:       String.t()        # agent name (from manifest basename) — agent-agnostic key
status:      :clean | :flagged | :insufficient_data
flags:       [Flag.t()]        # every applicable flag; [] when clean
computed_at: DateTime.t()      # provenance only; never feeds a threshold
```

Status lifecycle:
- `:insufficient_data` — fewer records than needed to evaluate (no history, or trace shorter than the
  rate signals require). The `:gate_breach` tripwire is still evaluated even on a short trace; only the
  rate/streak signals report insufficient-data.
- `:clean` — enough history, no flags raised.
- `:flagged` — one or more flags; `flags` lists **all** of them (totality, no suppression — FR-007).
- **Clearing**: status is recomputed from the current window each pass, so a flag whose condition has
  left the window simply does not appear in the next verdict — flags clear automatically (FR-007).

## Persistence shape — `StateStore "conformance"`

```text
%{ agent_name => Verdict.t() }   # verdicts keyed at top level by agent name
```

Single-writer `StateStore` (`data/conformance.term`, initial `%{}`). Written only by `run_pass/1`
via the **existing** `StateStore.apply_action("conformance", {:put, agent_name, verdict})` handler
(no new handler needed); read by the inventory via `StateStore.snapshot("conformance")[agent_name]`.

## Admin alert record — `data/admin_alerts.md`

Append-only markdown, written by `AgentOS.ConformanceAuditor.Alert`. One line per newly-raised/escalated
flag:

```
- [<iso8601>] agent=<name> flag=<type> severity=<sev> <description>
```

Never written to `data/run_log.md` (Decision 2). Notification-only — carries no action/deploy outcome.
