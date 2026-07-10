# Tasks: Re-run Checks for Existing Agents

**Feature**: `043-rerun-checks` | **Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)
**Contract**: [contracts/rerun-checks.md](./contracts/rerun-checks.md) | **Data model**: [data-model.md](./data-model.md)

Backend logic is built test-first (Constitution III). Run `mix test` from repo root
(`.venv/bin/python` is the default `PYTHON_BIN`). The suite must end fully green.

---

## Phase 1: Setup (shared infrastructure)

- [X] T001 Add the `check_reruns` StateStore child to the supervision tree in `lib/agent_os/application.ex` (path `Application.get_env(:agent_os, :check_reruns_path, "data/check_reruns.db")`, `initial: %{}`), placed alongside the other stores.
- [X] T002 Add the `AgentOS.Pipeline.RunLock` child to the supervision tree in `lib/agent_os/application.ex` (started after the StateStores, before the web endpoint).
- [X] T003 Add `"check_reruns"` to `@per_agent_stores` in `lib/agent_os/agent_lifecycle.ex` so a deleted agent's re-run record is wiped with its other per-agent state.

**Checkpoint**: `mix compile` clean; the app boots with the new store and lock.

---

## Phase 2: Foundational (blocking prerequisites for all stories)

- [X] T004 [P] Write `test/agent_os/pipeline/run_lock_test.exs`: `claim/1` returns `:ok` then `{:error, :busy}` on a second claim for the same agent; `release/1` frees it (idempotent); `busy?/1` reflects state; different agents are independent; calls against an unstarted lock are tolerant (not busy / no-op).
- [X] T005 Implement `AgentOS.Pipeline.RunLock` in `lib/agent_os/pipeline/run_lock.ex`: a GenServer holding `%{in_flight: MapSet.t()}` with `@spec`'d `claim/1`, `release/1`, `busy?/1`, each tolerant of the process being absent (catch `:exit` → not-busy/no-op, logged). Make T004 green.
- [X] T006 Define `AgentOS.Pipeline.Rerun.Record` struct in `lib/agent_os/pipeline/rerun.ex` with fields and `@type t` per data-model.md (`run_id`, `agent_name`, `code_hash`, `judge_verdict`, `security_verdict`, `outcome`, `reason`, `started_at`, `finished_at`), plus a `@moduledoc`.

**Checkpoint**: RunLock tested/green; Record type compiles. Core `Rerun` behaviour begins in Phase 3.

---

## Phase 3: User Story 1 — Recover a stranded agent (Priority: P1) 🎯 MVP

**Goal**: Re-run Stage 3 + Stage 5 against existing code/manifest; on pass, fresh verdicts key
to the current `code_hash` and `deploy_gate/3` opens — without deploying/approving/running.

**Independent test**: Take an agent with generated code and no verdicts, run the re-run, assert
both verdicts persist with the code hash and `Provisioner.deploy_gate/3` returns `:ok`.

- [X] T007 [P] [US1] In `test/agent_os/pipeline/rerun_test.exs`, add a setup that starts `InferenceBroker`, `CredentialProxy`, the `judge_results` / `security_review_results` / `check_reruns` StateStores, writes a temp agent (`main.py`, `models.py`, `execution_mode` sidecar) and manifest, and provides a `provider_fn` stub returning pass verdicts for judge + security (mirror `mock_provider` in `test/agent_os/pipeline/orchestrator_test.exs` and helpers in `test/agent_os/provisioner_test.exs`).
- [X] T008 [US1] Add the US1 test: `Rerun.run/2` on a verdict-less agent returns `{:ok, %Record{outcome: :passed}}`, persists `judge_results`/`security_review_results` entries whose `code_hash` equals `Provisioner.code_hash(agent, opts)`, and `Provisioner.deploy_gate(agent, :always_review, opts)` then returns `:ok`.
- [X] T009 [US1] Add the no-deploy test: after a passing `Rerun.run/2`, the agent has NO deployment record and NO `provenance` entry — the re-run did not deploy, approve, or run it (FR-004).
- [X] T010 [US1] Add the spend-cap test: an agent whose manifest `spend.cap` is tiny still completes a passing re-run (the setup token is uncapped), proving the runtime cap does not block a re-run.
- [X] T011 [US1] Implement `Rerun.eligible?/2` in `lib/agent_os/pipeline/rerun.ex`: `{:error, :system_agent}` for system agents, `{:error, :code_missing}` when `main.py`/`models.py` absent, `{:error, :manifest_missing}` when the manifest won't load, else `:ok` (opts `:agents_dir`, `:manifest_dir`).
- [X] T012 [US1] Implement `Rerun.run/2` in `lib/agent_os/pipeline/rerun.ex`: load manifest + code files; register an UNCAPPED setup token with `InferenceBroker` (mirror the `"orchestrator"` registration in `orchestrator.ex`) and unregister in an `after`; call `Stage3.generate/3` → `Stage3.run/3` → `Stage5.review/4` with the agent's real manifest; build and persist the `Record` to `check_reruns`; return `{:ok, record}` on `outcome: :passed`, else `{:error, record}`. MUST NOT call `Provisioner.deploy/3`/record provenance/start a run. Make T008–T010 green.
- [X] T013 [US1] Implement `Rerun.start/2` in `lib/agent_os/pipeline/rerun.ex`: run `eligible?/2`, then `RunLock.claim/1` (return `{:error, :busy}` if held), then spawn a detached task under `AgentOS.PipelineTaskSupervisor` that calls `run/2` and `RunLock.release/1` in an `after`; return `{:ok, run_id}`. Support a `:runner_fn` seam for tests.
- [X] T014 [US1] In `lib/agent_os_web/live/inventory_live.ex`, compute `code_present?` per card in `assign_agents_data/1` (`agents/<name>/main.py` exists) and render a "Re-run checks" button in the lifecycle-controls row only for non-system agents with code; add `handle_event("rerun_checks", %{"agent" => a}, socket)` calling `Rerun.start/1`, setting `rerun_started` on `{:ok, _}` (with a refresh) and `action_error` (human copy) on `{:error, reason}`.

**Checkpoint**: US1 is independently testable — a stranded agent becomes approvable after a
passing re-run, via the inventory button, with nothing waived.

---

## Phase 4: User Story 2 — A failed re-run keeps the agent blocked, visibly (Priority: P2)

**Goal**: A red or incomplete re-run leaves the agent blocked, with the failing check (or the
incompleteness) and its reasoning visible; the owner can retry.

**Independent test**: Re-run an agent whose code fails a check; assert the agent stays gate-
blocked and the record carries the failing verdict + reason.

- [X] T015 [P] [US2] In `test/agent_os/pipeline/rerun_test.exs`, add a failing-security test: with a `provider_fn` returning a `fail` security verdict, `Rerun.run/2` returns `{:error, %Record{outcome: :failed, security_verdict: :fail, reason: <non-nil>}}`, and `Provisioner.deploy_gate/2` stays `{:error, :security_review_failed}` (SC-002).
- [X] T016 [P] [US2] Add an incompleteness test: when a stage aborts before producing a verdict (e.g. `provider_fn` raises, or a missing judge spec), `Rerun.run/2` yields `outcome: :incomplete` with a `nil` verdict, the agent stays blocked, and the record is persisted so a retry is possible.
- [X] T017 [US2] Implement the outcome/reason derivation in `Rerun.run/2` (`lib/agent_os/pipeline/rerun.ex`): `:passed` iff both `:pass`; `:incomplete` if either verdict is `nil` (stage crash/abort); else `:failed`; set `reason` from the failing check's reasoning (or the incompleteness detail). Make T015–T016 green.
- [X] T018 [US2] In `lib/agent_os_web/live/inventory_live.ex`, render the failing check + reason on the card from the `check_reruns` record (reusing the judge/security badges already driven by the fresh verdicts), so a blocked agent shows *why* after a red/incomplete re-run.

**Checkpoint**: US2 independently testable — red/incomplete re-runs never open the gate and the
reason is visible.

---

## Phase 5: User Story 3 — The gate refusal points to the remedy (Priority: P3)

**Goal**: On a deploy-gate refusal, the message names the reason and offers the right remedy:
re-run checks for agents with code; re-create/delete for orphans.

**Independent test**: Attempt approval of a gate-refused agent (with and without code) and assert
the refusal copy offers the correct remedy.

- [X] T019 [P] [US3] In `test/agent_os_web/consent_live_test.exs`, add a test: approving a gate-refused agent that HAS code shows a refusal naming the reason and a "Re-run its checks from the inventory" link to `/inventory` (FR-006).
- [X] T020 [P] [US3] Add a test: approving a gate-refused agent with NO code (orphan) shows a refusal directing the owner to re-create or delete, with no re-run offered.
- [X] T021 [US3] Extend `gate_error_text/1` → `gate_error_text/2` in `lib/agent_os_web/live/consent_live.ex` (reason, `code_missing?`): code present → reason + re-run-from-inventory remedy; orphan → reason + re-create/delete remedy. Pass `socket.assigns.code_missing` from the `approve` handler and render any link via `<.link navigate="/inventory">`. Make T019–T020 green.

**Checkpoint**: US3 independently testable — refusals route the owner to the correct remedy.

---

## Phase 6: User Story 4 — Progress and history like a normal pipeline run (Priority: P3)

**Goal**: Live per-check progress in the inventory as the re-run runs, and a persisted outcome
visible after the fact.

**Independent test**: Trigger a re-run and observe `ProgressEvent`s per check plus a persisted
`check_reruns` record; a "last re-run" line renders on the card.

- [X] T022 [P] [US4] In `test/agent_os/pipeline/rerun_test.exs`, subscribe to `ProgressEvent.run_topic(run_id)` and assert `Rerun.run/2` emits `:judge` and `:security_review` `:started`/`:finished` events and a terminal `:pipeline` event carrying the outcome (FR-007).
- [X] T023 [US4] Emit the `ProgressEvent`s in `Rerun.run/2` (`lib/agent_os/pipeline/rerun.ex`) around each stage and at completion, using a fresh/opt `run_id`, via `ProgressEvent.new/5` + `broadcast/1`. Make T022 green.
- [X] T024 [US4] In `lib/agent_os_web/live/inventory_live.ex`, render a "Last checks re-run: <outcome> (<when>)" line on the card from the `check_reruns` store (the view already refreshes on the `:pipeline_progress` firehose it subscribes to), so the outcome stays visible after the fact (SC-005).

**Checkpoint**: US4 independently testable — progress is live and the outcome persists.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T025 [P] Add an inventory-view test in `test/agent_os_web/inventory_live_test.exs`: the "Re-run checks" button renders for a non-system agent with code and is absent for an orphan (manifest, no code); a `rerun_checks` click with a `:busy` lock surfaces the "already running" copy.
- [X] T026 Run `mix format` and Credo; ensure `@doc`/`@moduledoc` and intent comments cover the co-generation-isolation and spend-lift rationales in `rerun.ex` (Constitution VII).
- [X] T027 Run the full `mix test` suite from repo root and confirm it ends fully green (no pre-existing failures left behind); walk through `quickstart.md` steps 3–5 mentally against the implemented handlers.

---

## Dependencies & Execution Order

- **Setup (T001–T003)** → unblocks everything.
- **Foundational (T004–T006)** → RunLock + Record precede the core.
- **US1 (T007–T014)** is the MVP; depends on Foundational. Delivers the recovery path end-to-end.
- **US2 (T015–T018)** depends on US1's `Rerun.run/2` (extends outcome/reason handling + card copy).
- **US3 (T019–T021)** depends only on the existing `deploy_gate` + consent view — independent of US1's code path (can proceed in parallel once Setup is done).
- **US4 (T022–T024)** depends on US1's `Rerun.run/2` (adds progress emission + history line).
- **Polish (T025–T027)** last.

## Parallel Opportunities

- T004 and T006 are `[P]` (different files).
- Within a story, `[P]` test tasks (T007, T015/T016, T019/T020, T022, T025) can be authored
  together before their implementation task.
- US3 (consent-page remedy) can be built in parallel with US1/US2/US4 after Setup.

## Implementation Strategy

**MVP = Phase 1 + Phase 2 + Phase 3 (US1)**: a stranded agent recovers through the inventory
button, verdicts key to the current code, and the gate opens on green — nothing waived. Layer
US2 (visible failure), US3 (refusal remedy), and US4 (progress/history) incrementally; each is
independently testable.
