# Phase 1 Data Model: Re-run Checks

## New entity: `AgentOS.Pipeline.Rerun.Record`

A typed struct recording one check re-run. Persisted to the `check_reruns` StateStore keyed by
`agent_name` (latest re-run replaces the prior record for that agent, matching "gating always
uses the latest verdicts" — Assumption 3).

| Field | Type | Notes |
|-------|------|-------|
| `run_id` | `String.t()` | Keys the per-run `ProgressEvent` topic; stamped on the record for a refreshed UI to re-subscribe. |
| `agent_name` | `String.t()` | The examined agent. |
| `code_hash` | `String.t()` | `Provisioner.code_hash(agent_name, opts)` of the examined `main.py`+`models.py`; ties the record to the exact code version (FR-003). `""` if code unreadable. |
| `judge_verdict` | `:pass \| :fail \| :malfunction \| :error \| nil` | Stage 3 verdict status; `nil` if the stage did not complete. |
| `security_verdict` | `:pass \| :fail \| :error \| nil` | Stage 5 verdict status; `nil` if the stage did not complete. |
| `outcome` | `:passed \| :failed \| :incomplete` | `:passed` iff both verdicts are `:pass`; `:incomplete` if a stage crashed/aborted before producing a verdict; `:failed` otherwise. |
| `reason` | `String.t() \| nil` | Human-readable failure/incompleteness detail (e.g. the failing check's reasoning), for card display (FR-005). |
| `started_at` | `DateTime.t()` | |
| `finished_at` | `DateTime.t() \| nil` | `nil` while in flight. |

**Type**: full `@type t :: %Rerun.Record{...}` with the field types above. `@derive Jason.Encoder`
is not required (term-store persists the struct directly, as `PipelineRun` does).

### Derived outcome rule

```
outcome =
  cond do
    judge == :pass and security == :pass         -> :passed
    is_nil(judge) or is_nil(security)            -> :incomplete
    true                                         -> :failed
  end
```

A re-run that itself crashes before Stage 5 yields `security_verdict: nil` → `:incomplete`
(the agent "remains blocked exactly as before"; the owner can retry — FR-005, US2 scenario 2).

## Reused entities (unchanged shape)

- **`judge_results[agent_name]`** — `%{status, last_run, reasoning, code_hash}`. Written by
  `Stage3.run/3` (unchanged). A re-run overwrites the agent's slice with fresh values.
- **`security_review_results[agent_name]`** — `%AgentOS.Pipeline.Stage5.Verdict{status,
  reasoning, timestamp, code_hash}`. Written by `Stage5.review/4` (unchanged).
- **`AgentOS.Pipeline.ProgressEvent`** — `%{run_id, agent_name, stage, status, detail, at}`.
  Reused as-is; re-run emits `stage ∈ {:judge, :security_review, :pipeline}`.
- **Deploy gate** — `Provisioner.check_deploy_on_green/2` reads the two verdict stores and the
  current `code_hash`; unchanged. A green re-run makes it return `:ok` (SC-001); a red or
  stale/missing verdict keeps it `{:error, reason}` (SC-002).

## New in-memory state: `AgentOS.Pipeline.RunLock`

Not persisted (in-flight only). GenServer state: `%{in_flight: MapSet.t(String.t())}`.
Transitions: `claim(agent)` adds to the set (`{:error, :busy}` if already present);
`release(agent)` removes it. Lost on node restart by design (no run survives a restart).

## New StateStore: `check_reruns`

Added to the supervision tree alongside the other stores, path
`Application.get_env(:agent_os, :check_reruns_path, "data/check_reruns.db")`, `initial: %{}`.
Wiped per-agent on delete: add `"check_reruns"` to `AgentLifecycle.@per_agent_stores` so a
deleted agent leaves no orphan re-run record.
