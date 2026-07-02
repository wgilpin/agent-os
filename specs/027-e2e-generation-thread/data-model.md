# Phase 1 Data Model: E2E Generation Thread

Only one new entity is introduced. Everything else (Manifest, the Stage 3/5 Verdicts, the
Stage 4 AgentBody, deploy provenance) already exists and is reused unchanged.

## Entity: `PipelineRun`

Module: `AgentOS.Pipeline.Orchestrator.PipelineRun` (struct co-located with the orchestrator).
One record per end-to-end generation run for a single confirmed purpose. This is the
legibility unit (Constitution VIII) recorded in the `pipeline_runs` StateStore collection
and summarised in the run-log.

| Field | Type | Notes |
|-------|------|-------|
| `agent_name` | `String.t()` | Key. The agent the run generated. |
| `purpose` | `String.t()` | The confirmed one-line purpose from the `ElicitedSpec`. |
| `stages` | `[stage_outcome()]` | Ordered per-stage outcomes (see below), stages 2→6 as reached. |
| `judge_verdict` | `:pass \| :fail \| nil` | Mirror of the Stage 3 verdict; `nil` if the run stopped before Stage 3. |
| `security_verdict` | `:pass \| :fail \| nil` | Mirror of the Stage 5 verdict; `nil` if stopped before Stage 5. |
| `deploy_result` | `deploy_result() \| nil` | `Provisioner.deploy/3` return, or `nil` if never reached. |
| `provenance` | `:reviewed_human \| :skipped_in_envelope \| :dangerously_skipped \| :blocked \| nil` | Deploy provenance; `nil` unless Stage 6 ran. Sourced from `deploy/3`, not re-derived. |
| `outcome` | `:deployed \| :blocked \| :stopped` | Terminal state of the run. |
| `stopped_at` | `stage() \| nil` | The stage that halted the run (`nil` on full success). |
| `reason` | `term() \| nil` | Failure reason when `outcome: :stopped`. |
| `started_at` | `DateTime.t()` | Run start. |
| `finished_at` | `DateTime.t()` | Run end. |

### Types

```
@type stage :: :manifest | :agent | :judge | :security_review | :deploy
@type stage_status :: :ok | :error
@type stage_outcome :: %{stage: stage(), status: stage_status(), detail: term()}
@type deploy_result ::
        {:ok, provenance :: atom()}
        | {:blocked, ref :: String.t()}
        | {:error, term()}
```

### State transitions (outcome)

```
start
  └─ Stage 2 project+write manifest ──error──▶ outcome=:stopped, stopped_at=:manifest
  └─ Stage 4 synthesise body ─────────error──▶ outcome=:stopped, stopped_at=:agent
  └─ Stage 3 generate(blind)+run judge ─error/fail─▶ outcome=:stopped, stopped_at=:judge
  └─ Stage 5 security review ──────────error/fail─▶ outcome=:stopped, stopped_at=:security_review
  └─ Stage 6 deploy/3
        ├─ {:ok, prov}      ▶ outcome=:deployed, provenance=prov
        ├─ {:blocked, ref}  ▶ outcome=:blocked   (review-mode rail parked it for a human)
        └─ {:error, reason} ▶ outcome=:stopped, stopped_at=:deploy, reason=reason
```

Note: a **judge/security `:fail`** is distinct from a stage **`:error`** (crash/malformed
artifact). Both halt before deploy, but the recorded `reason`/`detail` differentiates
them so the inventory can say *which check failed* (spec Edge Cases; FR-007).

### Validation rules

- `stages` is append-only within a run and ordered by execution; the last element's
  `stage` equals `stopped_at` when `outcome != :deployed`.
- `outcome: :deployed` ⇒ `judge_verdict == :pass` **and** `security_verdict == :pass`
  (invariant mirrors `check_deploy_on_green/2`; the orchestrator never bypasses it).
- `outcome: :deployed` ⇒ `provenance != nil`.
- No `PipelineRun` may reach `:deployed` while any stage outcome has `status: :error`.

## Collection: `pipeline_runs` (StateStore)

- Single-writer, registered at boot alongside `judge_results`, `security_review_results`,
  `spend_ledger`, etc.
- Shape: `%{agent_name => PipelineRun.t()}` (latest run per agent; prototype scope keeps
  one, not a history list).
- Written only by the orchestrator via `StateStore.apply_action("pipeline_runs", {:put, agent_name, run})`.

## Reused entities (unchanged)

- `AgentOS.Manifest.t` — Stage 2 output; the safety artifact; machine-written here.
- `AgentOS.Pipeline.Stage3.Verdict` in `judge_results` — code-matches-manifest.
- `AgentOS.Pipeline.Stage5.Verdict` in `security_review_results` — smoke-detector verdict.
- `AgentOS.Pipeline.Stage4.AgentBody` — the synthesised `main.py`/`models.py`.
- Deploy provenance record (via `Provisioner.record_provenance/…`) — reused as the source
  of truth for `provenance`; `PipelineRun.provenance` mirrors it, never overrides it.
