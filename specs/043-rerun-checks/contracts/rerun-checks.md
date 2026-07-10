# Contract: Re-run Checks

## `AgentOS.Pipeline.Rerun`

The substrate seam for the partial-pipeline recovery re-run. The web layer calls only this
module (plus `RunLock` indirectly through it).

### `eligible?(agent_name, opts \\ []) :: :ok | {:error, reason}`

Pure eligibility check (no side effects). `reason ∈ {:system_agent, :code_missing,
:manifest_missing}`.

- `{:error, :system_agent}` when `AgentLifecycle.system_agent?/1` is true (FR-008).
- `{:error, :code_missing}` when `agents/<name>/main.py` or `models.py` is absent (FR-008,
  orphan case).
- `{:error, :manifest_missing}` when `manifests/<name>.md` cannot be loaded.
- `:ok` otherwise.

Opts: `:agents_dir` (default `"agents"`), `:manifest_dir` (default `"manifests"`).

### `start(agent_name, opts \\ []) :: {:ok, run_id :: String.t()} | {:error, reason}`

The UI entry point. Synchronously: (1) `eligible?/2`; (2) `RunLock.claim/1`
(`{:error, :busy}` if a run is already in flight for this agent — FR-009); (3) spawns a
detached task under `AgentOS.PipelineTaskSupervisor` that calls `run/2` and releases the lock
in an `after`. Returns `{:ok, run_id}` immediately so the caller can (already) observe live
progress via the firehose. Never blocks on the checks.

- Test seam: `:runner_fn` (default the real detached spawn) lets a LiveView test assert
  `start/2` was reached without running inference.

### `run(agent_name, opts \\ []) :: {:ok, Record.t()} | {:error, Record.t() | reason}`

The synchronous core (used by the task and directly in tests). Behaviour:

1. Load manifest (`manifests/<name>.md`) and code files (`main.py`, `models.py`).
2. Register the run token with `InferenceBroker` under a setup identity with an **uncapped**
   manifest (`cap: 1_000_000_000`); unregister in an `after` (D3 — spend never blocks a re-run).
3. Emit `ProgressEvent(:judge, :started)`; run `Stage3.generate/3` then `Stage3.run/3`;
   emit `:finished`/`:failed` with the verdict status.
4. Emit `ProgressEvent(:security_review, :started)`; run `Stage5.review/4`; emit
   `:finished`/`:failed`.
5. Emit terminal `ProgressEvent(:pipeline, <outcome>)`.
6. Build and persist the `Rerun.Record` to `check_reruns` (keyed by `agent_name`).
7. Return `{:ok, record}` when `outcome == :passed`, else `{:error, record}`.

**Guarantees:**
- MUST call `Stage3`/`Stage5` with the agent's **real** manifest (only the spend *cap* is
  lifted for the setup-scoped token) — same standards, same scope (Assumption 1, FR-002).
- MUST NOT call `Provisioner.deploy/3`, record provenance, approve, or start a run (FR-004).
- Fresh verdicts land in `judge_results`/`security_review_results` with the examined
  `code_hash` (via the reused stages) — so `deploy_gate/3` opens on green, stays closed on
  red/incomplete (FR-003, FR-005, SC-002).
- A stage crash yields a `nil` verdict and `outcome: :incomplete`; the agent stays blocked and
  the record shows the incompleteness (FR-005, US2).

Opts forwarded to the stages: `:provider_fn`, `:prices`, `:now`, `:model`, `:spec_dir`,
`:manifest_dir`, `:run_token`, `:runner_fn` (Stage 3 agent execution seam), `:run_id`.

## `AgentOS.Pipeline.RunLock` (GenServer)

- `claim(agent_name) :: :ok | {:error, :busy}` — adds `agent_name` to the in-flight set; busy
  if already present.
- `release(agent_name) :: :ok` — removes it (idempotent).
- `busy?(agent_name) :: boolean()` — membership test.

All three are tolerant of the process being absent (minimal test trees): absence ⇒ not busy /
no-op, logged at debug. Started in the supervision tree as `AgentOS.Pipeline.RunLock`.

## UI: `AgentOSWeb.InventoryLive`

- **Button**: a "Re-run checks" button in the lifecycle-controls row, rendered iff the card is
  a non-system agent **with** generated code (`code_present?`). `phx-click="rerun_checks"`,
  `phx-value-agent`.
- **Handler**: `handle_event("rerun_checks", %{"agent" => a}, socket)` calls `Rerun.start(a)`.
  On `{:ok, _run_id}` sets an inline "Checks re-running…" note (`rerun_started` assign) and
  refreshes; on `{:error, reason}` sets `action_error` with human copy (busy → "a check is
  already running for this agent — wait for it to finish"; code_missing/system_agent → matching
  copy). Progress and outcome then arrive via the existing `:pipeline_progress` firehose
  subscription, which re-renders the judge/security badges (FR-007).
- **History line**: a "Last checks re-run: <outcome> (<when>)" line on the card, read from the
  `check_reruns` store, so the outcome remains visible after the fact (FR-007, SC-005).

## UI: `AgentOSWeb.ConsentLive`

- `gate_error_text/2` (reason, `code_missing?`):
  - code present → reason sentence + "Re-run its checks from the inventory." with a
    `<.link navigate="/inventory">` (FR-006, US3 scenario 1).
  - orphan (no code) → reason sentence + "Re-create it from the Create agent page, or delete it
    from the inventory." (no re-run offered — nothing to check) (FR-006, US3 scenario 2).
- The `approve` handler passes `socket.assigns.code_missing` into `gate_error_text/2`.

## Non-goals (explicit)

- No manifest projection, no ExecutionMode re-classification write, no code synthesis, no
  deploy, no provenance write, no agent run.
- No automatic/scheduled re-runs; no conformance re-run; no grant/capability editing.
