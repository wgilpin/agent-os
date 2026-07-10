# Phase 0 Research: Re-run Checks

All questions below are resolved from the existing codebase; there are no external unknowns.

## D1. How to re-run only Stage 3 + Stage 5 without the rest of the pipeline

**Decision**: A new `AgentOS.Pipeline.Rerun` module calls, in order:
`Stage3.generate/3` → `Stage3.run/3` → `Stage5.review/4`, loading the manifest from
`manifests/<name>.md` and the code files from `agents/<name>/{main.py,models.py}`. It skips
Stage 2 (manifest projection), the ExecutionMode classify step's *write* (it reads the
existing on-disk `execution_mode` sidecar via `Stage3.resolve_mode`), Stage 4 (code
synthesis), and Stage 6 (deploy).

**Rationale**: The orchestrator (`orchestrator.ex`) already threads exactly these calls;
`Stage3.run/3` persists `judge_results` with `Provisioner.code_hash(agent_name, opts)`, and
`Stage5.review/4` persists `security_review_results` with `Provisioner.code_hash(code_files)`.
Both hashes derive from the same `main.py`+`models.py` bytes, so a re-run's verdicts are
already keyed to the examined code — `check_deploy_on_green/2` compares them to the current
hash for staleness. Reusing the stages verbatim guarantees "same standards, same scope"
(Assumption 1) with zero duplication.

**Alternatives considered**: (a) Parameterising `Orchestrator.run` with a "checks-only" flag
— rejected: it would entangle deploy/manifest/classify branches with a partial mode and risk
the full-pipeline tests. (b) Re-implementing the judge/security calls inline — rejected:
duplicates prompt/verdict logic and violates Simplicity.

## D2. Execution-mode input for Stage 3 without regeneration

**Decision**: Do not classify. `Stage3.generate/3`/`run/3` call `resolve_mode/2`, which falls
back to `ExecutionMode.load(agent_name, opts)` (the on-disk sidecar written at creation time)
when no `:execution_mode` opt is passed. The re-run passes no `:execution_mode`, so the
agent's recorded mode is reused — no LLM classification, no regeneration.

**Rationale**: Keeps the re-run's cost bounded to the two checks (SC-004) and preserves
co-generation isolation (the judge still derives from manifest + purpose + the one recorded
mode bit, never from the code).

## D3. Not blowing the agent's runtime spend cap (Assumption 2 / spend memory)

**Decision**: Before running the stages, register the run token with `InferenceBroker` under a
setup identity using an **uncapped** manifest (`cap: 1_000_000_000`), exactly as
`Orchestrator.execute_stages` registers its `"orchestrator"` token; unregister in an `after`.
`Stage3.run/3` additionally re-registers the token under the agent name with its own uncapped
`eval_manifest` (already in `stage3_judge.ex`), and `Stage5.review/4` meters on the passed
token. So neither check can be blocked by the agent's manifest `spend.cap`.

**Rationale**: Re-running checks is setup activity, not the agent's own runtime spending
(Assumption 2). This mirrors the merged spend-cap-lift fix for Stage 3 judging.

**Alternatives considered**: Temporarily editing the manifest cap — rejected: mutates
durable state and is racy. Token-scoped registration is the established pattern.

## D4. Live progress + persisted history (FR-007)

**Decision**: Emit `AgentOS.Pipeline.ProgressEvent`s for `:judge` and `:security_review`
(`:started`/`:finished`/`:failed`) and a terminal `:pipeline` event, using a fresh `run_id`.
`InventoryLive` already subscribes to `ProgressEvent.all_topic()` and refreshes agent data on
any `{:pipeline_progress, _}` — so the judge/security badges update live with no new
subscription. Persist a typed `Rerun.Record` to a new `check_reruns` StateStore keyed by
`agent_name`; render a "Last checks re-run" line on the card from it.

**Rationale**: Reuses the exact mechanism the UI already renders (the task brief calls for
this). A dedicated store keeps re-run history separate from `pipeline_runs` (whose
deploy-centric `PipelineRun` outcome enum — `:deployed | :blocked | :stopped` — does not model
a no-deploy re-run cleanly) while remaining "a record like PipelineRun".

**Alternatives considered**: Overloading `pipeline_runs`/`PipelineRun` — rejected: would need
a new outcome variant rippling into `Orchestrator.record_run`'s pattern match and would
overwrite the agent's genuine last generation run. A separate typed record is cleaner and
strongly typed (Constitution V).

## D5. One-run-per-agent concurrency (FR-009)

**Decision**: A tiny `AgentOS.Pipeline.RunLock` GenServer holding a `MapSet` of in-flight
agent names: `claim/1 :: :ok | {:error, :busy}`, `release/1`, `busy?/1`. `Rerun.start/2`
claims synchronously (so the UI gets an immediate `{:error, :busy}` refusal) before spawning
the detached task, and the task releases in an `after`. Calls are tolerant of an absent
process (minimal test trees) — absence means "not busy", matching the codebase's
`safe_*` idioms.

**Rationale**: Simplest correct primitive; synchronous claim gives a same-request refusal
(SC-003). A `Registry` was considered but its auto-release is tied to the *registering*
process, which does not fit a synchronous-claim / async-worker split; a MapSet GenServer is
simpler to reason about here. Because in production `Orchestrator.run` is started only from
`ElicitationLive` for brand-new agents (which have no inventory card yet), re-run-vs-pipeline
contention is practically impossible; the lock fully covers the realistic re-run-vs-re-run
case, and `busy?/1` is available should a pipeline claim be added later.

## D6. Consent-page refusal remedy (FR-006)

**Decision**: `ConsentLive` already computes `code_missing` at mount. Extend
`gate_error_text/1` → `gate_error_text/2` taking the reason and `code_missing?`: for agents
**with** code, append "Re-run its checks from the inventory." with a link to `/inventory`;
for **orphans** (no code), keep the "re-create it from the Create agent page / delete it"
guidance. The existing missing-code warning banner already covers the orphan case; the gate
refusal text now names the reason *and* the remedy.

**Rationale**: Discoverability without leaking internals (SC-003). Minimal change to one
private function + a link in the banner.

## D7. Eligibility for the "Re-run checks" button (FR-001, FR-008)

**Decision**: Show the button on a card iff the agent is **not** a system agent
(`AgentLifecycle.system_agent?/1` — already used to hide system agents from inventory) **and**
has generated code (`agents/<name>/main.py` exists). `assign_agents_data/1` computes a
`code_present?` boolean per card; the button renders under the existing lifecycle-controls
row. Orphans (manifest, no code) show no button — their remedy is recreate/delete, already
surfaced elsewhere.

**Rationale**: Matches FR-008 (refuse for no-code and system agents) at the UI surface, and
`Rerun.start/2` re-checks the same conditions server-side so the refusal is enforced, not
merely hidden.
