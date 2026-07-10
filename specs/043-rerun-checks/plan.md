# Implementation Plan: Re-run Checks for Existing Agents

**Branch**: `043-rerun-checks` | **Date**: 2026-07-10 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/043-rerun-checks/spec.md`

## Summary

Add a **partial-pipeline recovery path** that re-runs the two safety checks — Stage 3
(blind compliance judge) and Stage 5 (security review) — against an agent's *existing*
generated code (`agents/<name>/main.py`, `models.py`) and manifest (`manifests/<name>.md`),
with **no elicitation and no code regeneration**. Fresh verdicts persist to the existing
`judge_results` / `security_review_results` StateStores keyed to the current `code_hash`, so
a green re-run opens `Provisioner.deploy_gate/3` exactly as a fresh generation would — while
the re-run itself never deploys, approves, or runs the agent.

The core is a new thin substrate module `AgentOS.Pipeline.Rerun` that reuses
`Stage3.generate/3` + `Stage3.run/3` + `Stage5.review/4` verbatim, registers an **uncapped
setup token** with `InferenceBroker` (mirroring the orchestrator's `"orchestrator"`
registration so the agent's runtime spend cap can never block a re-run), emits
`ProgressEvent`s over PubSub for live UI progress, and persists a typed run record to a new
`check_reruns` StateStore. A small `AgentOS.Pipeline.RunLock` GenServer enforces
one-run-per-agent (FR-009). The web layer gains a **"Re-run checks"** action on eligible
inventory cards (`InventoryLive`) and an extended deploy-gate refusal on the consent page
(`ConsentLive`) that routes owners to the remedy.

## Technical Context

**Language/Version**: Elixir ~1.16 / OTP 26 (BEAM control plane)
**Primary Dependencies**: Phoenix 1.7, Phoenix.LiveView 0.20, Phoenix.PubSub, Exqlite (StateStore backend)
**Storage**: Single-writer `StateStore` GenServers (SQLite-backed term store) + git-backed markdown files (`manifests/<name>.md`, `agents/<name>/`). No external DB. One new store: `check_reruns`.
**Testing**: ExUnit, hermetic (temp-dir StateStores, `provider_fn` broker stubs, injected `now`). No live remote calls (Constitution IV). `mix test` from repo root; `.venv/bin/python` is the default `PYTHON_BIN`.
**Target Platform**: Local BEAM node serving a Phoenix LiveView dashboard.
**Project Type**: Elixir/OTP control plane with a Phoenix LiveView web layer (`lib/agent_os/`, `lib/agent_os_web/`).
**Performance Goals**: N/A — single-owner prototype; a re-run is an interactive, one-at-a-time action.
**Constraints**: No inline JS (global rule); no external DB; single-writer-per-store; manifest is privileged-read (never crosses the port boundary); re-run is setup activity, never metered against the agent's runtime cap; recovery goes *through* the checks, never around them.
**Scale/Scope**: A handful of agents; one new core module + one lock GenServer + one store; two web surfaces touched.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Simplicity First** — PASS. Reuses `Stage3`/`Stage5` verbatim, the existing
  `ProgressEvent`/PubSub mechanism, `InferenceBroker` registration pattern, and the
  `Task.Supervisor` fire-and-forget pattern already used by the elicitation pipeline. New
  code is one thin orchestration module, one tiny lock GenServer, and one StateStore.
- **II. Explicit Scope Control** — PASS. Scope is exactly the four stories + nine FRs.
  Explicitly OUT of scope (not built): re-eliciting, regenerating or editing agent code;
  automatic/scheduled re-runs; changing the approval/consent flow; re-running conformance.
- **III. Test-Driven Backend** — PASS. All backend logic (`Rerun`, `RunLock`) is built
  test-first. The task brief explicitly directs mirroring `inventory_live_test.exs` /
  `consent_live_test.exs`, so the two web surfaces get focused `Phoenix.LiveViewTest`
  coverage for the new action and refusal copy (the views stay thin — all logic sits in the
  tested `Rerun`/`RunLock`/`Provisioner` seams).
- **IV. No Live Dependencies in Tests** — PASS. All model calls route through
  `InferenceBroker` with `provider_fn` stubs; StateStores are temp-dir; clock is injected.
- **V. Strong Typing, No Bare Maps** — PASS. `Rerun.Record` is a typed struct with a full
  `@type`/`@spec`; reuses typed `Manifest`, `Stage3.Verdict`, `Stage5.Verdict`,
  `ProgressEvent`. `RunLock` API is `@spec`'d.
- **VI. Loud Failures** — PASS. Every refusal/failure path logs with context and returns a
  typed `{:error, reason}`; broker/store absence in minimal trees is tolerated-and-logged,
  matching existing style.
- **VII. Self-Documenting** — PASS. Every new function gets a `@doc`; the co-generation
  isolation and spend-lifting rationales are carried as intent comments.
- **VIII. Legibility** — PASS. The inventory remains the standing legible view; re-run
  progress and outcome are rendered there live (via the firehose the view already
  subscribes to) and persist to `check_reruns` for after-the-fact history (FR-007).
- **IX. Substrate Owns State & Lifecycle** — PASS. Verdict writes stay inside `Stage3`/
  `Stage5`; the run record is written by the substrate `Rerun` module to a single-writer
  store; the web layer calls only `Rerun`/`RunLock`. No agent-specific vocabulary enters the
  kernel — everything is generic over `agent_name`.
- **X. No Ambient Authority** — PASS. A re-run confers no capability and widens no
  authority: it evaluates the agent under its *real* manifest grants (only the spend *cap*
  is lifted for the setup-scoped judging, exactly as Stage 3 already does at deploy time).
- **XI. Deterministic Gate Is the Only Firewall** — PASS (central). The re-run refreshes
  the LLM smoke-detector verdicts; it does **not** deploy or run. The deterministic
  `deploy_gate/3` remains the sole boundary — a red or incomplete re-run leaves the agent
  blocked. Recovery goes through the gate, never around it (SC-002).
- **XII. Enforcement Precedes Generation** — N/A (no change to enforcement/generation ordering).

**Result: PASS.** No violations; Complexity Tracking left empty.

## Project Structure

### Documentation (this feature)

```text
specs/043-rerun-checks/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output (manual walkthrough / verification)
├── contracts/
│   └── rerun-checks.md  # Rerun + RunLock public contract; UI + gate-refusal behaviour
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

```text
lib/agent_os/
├── pipeline/
│   ├── rerun.ex               # NEW — partial-pipeline re-run of Stage 3 + Stage 5
│   ├── run_lock.ex            # NEW — one-run-per-agent in-flight lock (GenServer)
│   ├── stage3_judge.ex        # (reuse) generate/3 + run/3, persists judge_results + code_hash
│   ├── stage5_review.ex       # (reuse) review/4, persists security_review_results + code_hash
│   └── progress_event.ex      # (reuse) live-progress broadcast (per-run + firehose topics)
├── provisioner.ex             # (reuse) deploy_gate/3, check_deploy_on_green/2, code_hash/2
└── application.ex             # + check_reruns StateStore child, + RunLock child

lib/agent_os_web/live/
├── inventory_live.ex          # + "Re-run checks" button (eligible cards), handler, last-run line
└── consent_live.ex            # + gate-refusal remedy (re-run link for code agents; recreate/delete for orphans)

test/agent_os/pipeline/
├── rerun_test.exs             # NEW — pass/fail/incomplete, staleness, spend-cap-lift, no-deploy, refusals
└── run_lock_test.exs          # NEW — claim/release/busy, auto-release on owner exit

test/agent_os_web/
├── inventory_live_test.exs    # + button visible for eligible agents, hidden for system/orphan; click triggers
└── consent_live_test.exs      # + refusal offers re-run (code) vs recreate/delete (orphan)
```

**Structure Decision**: Existing Elixir/OTP + Phoenix layout. New backend logic lives under
`lib/agent_os/pipeline/` (mirrored tests under `test/agent_os/pipeline/`); the two touched web
modules keep all logic in the substrate seams. No new directories.

## Complexity Tracking

> No Constitution violations — table intentionally empty.
