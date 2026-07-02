# Phase 0 Research: E2E Generation Thread + World-B on a Generated Agent

All questions below arose from the Technical Context. No `NEEDS CLARIFICATION` markers
remained in the spec; these resolve the *how* against the existing code.

## R1 — Orchestrator shape: synchronous `with` chain vs GenServer/Saga

- **Decision**: A plain synchronous function `AgentOS.Pipeline.Orchestrator.run/2..3` built
  as an Elixir `with` chain over the existing stage functions. No process, no state machine.
- **Rationale**: Constitution I (simplicity) and IX (agents are invocation-scoped;
  "looping" is a trigger re-invoking, never a long-lived process). Each stage is already a
  pure-ish function returning `{:ok, _} | {:error, _}`, so a `with` chain threads artifacts
  and short-circuits on the first error — exactly the "stop before deploy on any red"
  requirement (FR-005/FR-007). A GenServer/Saga would add lifecycle state the substrate
  does not need for a run-to-completion sequence.
- **Alternatives considered**: (a) GenServer per run — rejected: no concurrency or
  long-lived state to own; the substrate already owns persisted state. (b) Reuse
  `RunSupervisor`/`RunWorker` — rejected: those run a *deployed* agent workload, not the
  generation pipeline; conflating them would leak generation into the run path.

## R2 — Artifact threading between stages (exact wiring)

Verified stage entrypoints:

| Stage | Entry | Input | Output |
|-------|-------|-------|--------|
| 2 | `AgentOS.Manifest.Projection.project/1` then `.write/2` | confirmed `ElicitedSpec.t` | `{:ok, Manifest.t}`; manifest file at `manifests/<name>.md` |
| 3 | `AgentOS.Pipeline.Stage3.generate/3` then `.run/2` | `agent_name`, `Manifest.t` | `Verdict` persisted to `"judge_results"` |
| 4 | `AgentOS.Pipeline.Stage4.generate/3` | `agent_name`, `Manifest.t` | `AgentBody` written to `agents/<name>/main.py` + `models.py` |
| 5 | `AgentOS.Pipeline.Stage5.review/4` | `agent_name`, `Manifest.t`, `code_files` | `Verdict` persisted to `"security_review_results"` |
| 6 | `AgentOS.Provisioner.deploy/3` | `manifest_path`, `review_mode`, `opts` | reads both verdict stores, checks green, hands to review-mode rail |

- **Decision**: The orchestrator holds the projected `Manifest.t` and the Stage-4
  `code_files` in-scope and passes them directly to each stage. It does **not** re-derive
  or re-read them. Stages 3 and 5 already persist their verdicts to the two StateStore
  collections that `Provisioner.check_deploy_on_green/2` reads, so the orchestrator does
  not thread verdicts into deploy by hand — it just invokes `deploy/3` last, which is the
  existing contract. This keeps Stage 6 untouched (FR-003).
- **Ordering note**: Stage 3 (judge) is generated **blind** to Stage 4 (per spec 014/015 —
  independent derivation is the co-generation mitigation). The orchestrator therefore
  generates the judge spec and the agent body from the same `Manifest.t` without feeding
  one into the other. Judge *run* (Stage 3 `.run`) needs the written code, so the order is:
  Stage 2 → Stage 4 (write code) → Stage 3 (generate blind + run against code) → Stage 5 →
  Stage 6. Confirmed against `check_deploy_on_green` which compares each verdict's
  `code_hash` to the current on-disk `code_hash(agent_name)` — so the code must be written
  before either verdict is produced, else verdicts are `:stale_verdict`.
- **Alternatives considered**: threading verdicts as function args into a modified
  `deploy/3` — rejected: changes Stage 6's contract (violates FR-003); the store-read path
  is what 017 already ships and what world-B assumes.

## R3 — Retargeting the world-B battery at a generated agent

- **Observation**: `test/agent_os/world_b_test.exs` builds a hand-authored `%Manifest{}`
  in `setup` and runs BC-1…BC-7 as `Gate.evaluate/…`, `Gate.partition_batch/…`, and
  by-construction payload/trigger/approval probes using `test/fixtures/world_b/hostile.ex`.
  The breach cases are **manifest-driven**: they assert the gate denies actions outside the
  manifest's grants and that manifest fields never reach an agent-bound surface. They do
  not execute the agent's Python body — the gate sits between proposed actions and effect.
- **Decision**: The new `world_b_generated_test.exs` reuses the identical BC-1…BC-7
  describe blocks and hostile fixtures, but its `setup` obtains the manifest from **Stage 2
  projection of a confirmed spec** (machine-written) and synthesises the agent body via
  **Stage 4** (machine-written), both behind injected stubs. Because the BC cases are
  parameterised by `context.manifest` + `agent_name`, retargeting the setup is sufficient
  and **every case is preserved** (SC-004). BC-7 (read the manifest) gains force here: it
  now proves a *machine-written* manifest is equally unreadable.
- **How "machine-written body" strengthens it**: BC-3 (exfiltrate / no-bypass) and BC-5
  (forge trigger) assert that only gate-approved actions reach the effector and that
  agent-emitted trigger-shaped strings fire zero runs — properties that hold by
  construction regardless of what the body contains. Running them with a Stage-4-authored
  body demonstrates the guarantee does not depend on trusted code.
- **Alternatives considered**: parameterising the *existing* `world_b_test.exs` to run
  twice (hand-written + generated) — rejected: keeps the two proofs coupled and risks
  weakening the original suite; a separate module keeps the hand-written baseline pristine
  (Constitution II) and makes the "generated" acceptance independently runnable.
- **Live-call safety**: Stage 2 needs no model; Stages 3/4/5 accept `provider_fn` stubs.
  The generated-target setup uses a fixed stubbed body + stubbed verdicts so the test is
  deterministic (Constitution IV).

## R4 — Where the run is recorded (legibility)

- **Decision**: Add a `pipeline_runs` collection to `StateStore` (single-writer,
  registered at boot like the other collections) keyed by `agent_name`, holding the
  `PipelineRun` struct. The orchestrator also appends one human-readable line per run to
  the git-backed `RunLog`. The standing `Inventory` already surfaces judge +
  security-review verdicts and deploy provenance; it is extended **only** if the run
  thread (which stage stopped it) is not already derivable from those — the failure
  attribution field on `PipelineRun` is the minimal addition.
- **Rationale**: Constitution VIII/IX — the substrate owns the record; the outcome is
  readable without asking the agent; append-only markdown for the trace.
- **Alternatives considered**: a dedicated ETS table or process — rejected: violates
  "single writer per mutable store" and adds a store the substrate would have to supervise.

## R5 — Where the "reply to recruiter emails" worked example lives

- **Decision**: As a **test fixture** (`test/fixtures/generation/`) — a confirmed
  `ElicitedSpec` for the recruiter purpose plus the stubbed Stage-2/4 outputs used to drive
  the orchestrator test deterministically. No "recruiter" string appears in `lib/agent_os/`.
- **Rationale**: Constitution IX — the substrate is agent-agnostic; a specific agent's
  domain vocabulary in kernel code is a leak. The orchestrator takes `agent_name` + spec as
  data; the recruiter example is one such datum, owned by the test.
- **Alternatives considered**: a `manifests/recruiter.md` committed at repo root — rejected:
  it would look like a standing deployed agent and muddy the discovery-agent baseline;
  fixtures are scoped to the test.

## R6 — Failure semantics / partial run

- **Decision**: The `with` chain returns `{:error, {stage, reason}}` on the first failing
  stage; the orchestrator records a `PipelineRun` with `outcome: :stopped`,
  `stopped_at: <stage>`, and the reason, appends a run-log line, and returns without ever
  calling `deploy/3`. A stage crash (raise/exit) is caught at the orchestrator boundary,
  logged (Constitution VI), and recorded identically — no partial deploy, no lost failure
  (FR-007, SC-006).
- **Rationale**: matches "0 deploys on any red" and "failure attributed to a stage".
