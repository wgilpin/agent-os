---
description: "Task list for Sandbox Generated Agents (044)"
---

# Tasks: Sandbox Generated Agents

**Input**: Design documents from `/specs/044-sandbox-generated-agents/`
**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/dispatch.md](contracts/dispatch.md)

**Tests**: INCLUDED — this is backend Elixir logic (Constitution III, test-first) and the spec
mandates the adversarial containment probe (FR-008) and the world-B regression (FR-010).
Docker-dependent tests carry `@tag :docker` and are excluded by the default suite
(`test/test_helper.exs`); run them with `mix test --include docker`.

**Organization**: Grouped by user story. US1 and US2 are both P1 and ship together (the MVP);
US3 (P2) is the no-back-door regression on the same dispatch code.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1 / US2 / US3 — maps to the spec's user stories

## Path Conventions

Single project: Elixir substrate under `lib/agent_os/`, Python workloads under `agents/`,
tests under `test/agent_os/`, config under `config/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Source artifacts every story needs — the runtime image definition and config wiring.

- [x] T001 [P] Create the generic generated-agent runtime image Dockerfile at `agents/generated.Dockerfile`: reuse the `agents/discovery/Dockerfile` pattern (FROM python:3.11-slim, non-root `app` uid/gid 1000, `uv sync --frozen --no-dev` to bake `pydantic`/`google-genai`, `PYTHONPATH=/app`, `PYTHONUNBUFFERED=1`) but **omit** `COPY agents/` and **omit** any agent-specific `ENTRYPOINT` (the body arrives via a read-only mount at runtime). (FR-002, research D1)
- [x] T002 [P] Add config keys in `config/config.exs`: `:agent_image` (default `"agent-discovery:dev"`) and `:generated_agent_image` (default `"agent-generated:dev"`). (data-model.md → Configuration keys)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The generated-agent image must exist before any docker-tagged story test can run.

**⚠️ CRITICAL**: Blocks the docker-tagged tests in US1/US2.

- [x] T003 Build the image `docker build -t agent-generated:dev -f agents/generated.Dockerfile .`, then verify per [quickstart.md](quickstart.md) §1 that `pydantic`+`google.genai` import inside the container and that `/app/agents/discovery` is **absent** (no baked agent code). (FR-002)

**Checkpoint**: Runtime image ready — dispatch and containment work can proceed.

---

## Phase 3: User Story 1 - A generated agent runs jailed (Priority: P1) 🎯 MVP

**Goal**: Production dispatch of a generated agent executes its body inside the container
sandbox (network none, read-only root, non-root, limits), reaching the model over the
inference channel exactly as before — via the **same** `Sandbox.build_argv/1` path as the
config agent, differing only in image + code mount + entrypoint.

**Independent Test**: Dispatch a deployed generated agent with no `agent_cmd` override; confirm
from the run-log + container metadata it ran via `agent-generated:dev` (not host python),
reached the broker, and produced its outcome record.

### Tests for User Story 1 ⚠️ (write first, ensure they FAIL)

- [x] T004 [P] [US1] In `test/agent_os/run_worker_transcript_test.exs`, add a test that a generated agent dispatched with an explicit **non-docker** `agent_cmd` (e.g. a stdin-echo script) receives the `{roster}`+`trigger_input` payload and **no** bookmark items — proving the payload/bookmark discriminator keys on config-agent identity, not `cmd == "docker"`. (research D3, contracts/dispatch.md)
- [x] T005a [P] [US1] Unit-test `dispatch_spec/3` in `test/agent_os/run_worker_dispatch_test.exs` (no Docker): for a generated agent name it returns image `agent-generated:dev`, `entrypoint: "/app/.venv/bin/python"`, `cmd_args: ["/app/agents/<name>/main.py"]`, and mounts = `[inference_uds, {Path.expand("agents/<name>"), "/app/agents/<name>:ro"}]` with the UDS as the only non-`:ro` mount; for the config agent it returns the discovery image, `nil` entrypoint/cmd_args, and no code mount. (FR-001, FR-003, FR-004, FR-007, US1-AC3)
- [x] T005b [P] [US1] Add `test/agent_os/generated_dispatch_test.exs` with a `@tag :docker` end-to-end test: deploy a generated agent, `RunWorker.run_once(agent: name, trigger: :timer)` with no override, assert the run-log records `status=ok` and the run reached the broker over the UDS. (US1-AC1/AC2, SC-003)
- [x] T006 [P] [US1] Add loud-failure tests: `code_unmountable` (missing `agents/<name>/` — **no docker needed**, pre-flight checks the dir first) asserting run-log `failure_cause=code_unmountable` and no host fallback; plus `@tag :docker` tests for `image_unavailable` (bogus image name) and `runtime_unavailable` (documented manual/daemon-down check). (FR-009, edge cases, SC-005)

### Implementation for User Story 1

- [x] T007 [US1] In `lib/agent_os/run_worker.ex`, **delete** the block (~lines 104-113) that injects `agent_cmd: python_bin()` + `agent_args: ["agents/<name>/main.py"]` for non-config agents. (FR-005, research D5)
- [x] T008 [US1] In `run_worker.ex` docker-branch command builder, select per agent: `image` = `:agent_image` when config agent else `:generated_agent_image`; for generated agents set `entrypoint: "/app/.venv/bin/python"`, `cmd_args: ["/app/agents/<name>/main.py"]`, and append the read-only code mount `{Path.expand("agents/<name>"), "/app/agents/<name>:ro"}` alongside the existing inference-UDS mount. Keep the config agent's existing behaviour (baked entrypoint, no code mount). Retain the explicit-`:agent_cmd`-override guard unchanged. Extract this selection into a pure function `dispatch_spec(agent_name, config_agent, opts) :: %{image, entrypoint, cmd_args, mounts}` so it is unit-testable without Docker (makes T005a pass). (FR-002, FR-003, FR-004, FR-006, contracts/dispatch.md)
- [x] T009 [US1] In `run_worker.ex` `execute_run/6`, replace the `cmd == "docker"` discriminator (bookmark load + full `{state, items}` payload) with a `config_agent?` boolean (`agent_name == Path.basename(cfg.manifest_path, ".md")`), so only the config agent loads/sanitizes bookmarks and gets the full payload; generated agents keep `{roster}`+`trigger_input`. (research D3 — makes T004 pass)
- [x] T010 [US1] In `run_worker.ex`, add the loud pre-flight before `PortRunner.run` in the docker path: (a) if generated and `not File.dir?(Path.expand("agents/<name>"))` → `Logger.error` + run-log `failure_cause=code_unmountable` + `{:error, :code_unmountable}`; (b) `System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true)` nonzero → classify daemon-down (`runtime_unavailable`) vs missing (`image_unavailable`), `Logger.error` + run-log cause + error tuple. Never fall back to an unconfined run. (FR-009, research D4 — makes T006 pass)

**Checkpoint**: A generated agent runs fully jailed end-to-end; every failure mode is loud.

---

## Phase 4: User Story 2 - Containment proven against hostile code (Priority: P1)

**Goal**: A deliberately hostile generated body cannot read host files outside its mounts,
open an outbound connection, or write outside `/scratch`; each attempt fails and is logged.

**Independent Test**: Run the containment probe under `agent-generated:dev` with a read-only
code mount; assert all three escape attempts are refused and surfaced in a log/run record.

### Tests for User Story 2 ⚠️

- [x] T011 [P] [US2] Add a hostile probe body fixture at `test/fixtures/agents/containment_probe/main.py` (bare-import style) whose three sub-probes attempt: (a) read a host path outside its mounts (e.g. `/etc/shadow` or a host home file), (b) `socket.create_connection(("8.8.8.8", 53))`, (c) write to `/app/agents/containment_probe/pwned` (outside `/scratch`). Each prints a marker and **exits non-zero on the expected refusal so `RunWorker` records a `failure_cause` rather than `status=ok`.** (FR-008)
- [x] T012 [US2] Add `test/agent_os/generated_containment_test.exs` (`use ExUnit.Case, async: false`, each case `@tag :docker`, modelled on `isolation_test.exs`): run the probe body **via `RunWorker.run_once` (so refusals land in the run-log)** through the generated-agent sandbox path (image `agent-generated:dev`, code mounted `:ro`) and assert — as three vectors — host-file read denied, outbound socket refused, out-of-scratch write denied, and that each refusal is surfaced in the run-log (`failure_cause`) and/or logs, not swallowed. (FR-008, FR-009, US2-AC1..AC4, SC-002)

**Checkpoint**: The sandbox is proven, not merely claimed; a regression fails the build.

---

## Phase 5: User Story 3 - The bypass path cannot be reached in production (Priority: P2)

**Goal**: There is structurally no production route that dispatches a generated agent as an
unconfined host process; the explicit override still works.

**Independent Test**: Inspect production dispatch for a generated agent name with no override →
resolves to the container runtime; a test-supplied explicit override still dispatches as directed.

### Tests for User Story 3 ⚠️

- [x] T013 [P] [US3] In `test/agent_os/run_worker_transcript_test.exs` (or `generated_dispatch_test.exs`), add a test asserting that `RunWorker.run_once(agent: gen_name)` with **no** `agent_cmd` builds a `"docker"` dispatch (never `.venv/bin/python`), and a companion test asserting an explicit `agent_cmd: "echo"` override is honoured unchanged. (FR-005, FR-006, US3-AC1/AC2)
- [x] T014 [P] [US3] Add a guard test that reads `lib/agent_os/run_worker.ex` and asserts the removed dispatch structure is absent — specifically that no `agent_name != config_agent` branch injects `agent_cmd:`/`agent_args:` into `opts`. (The `python_bin/0` helper and the Provisioner rescue fallback legitimately remain and must NOT trip this guard.) Behavioral coverage is T013; this is the structural back-stop. (FR-005)

### Implementation for User Story 3

- [x] T015 [US3] Confirm the dispatch code from US1 (T007-T010) satisfies T013/T014 with no further change; if the greppable bypass string persists anywhere (e.g. `python_bin/0` now only used by the Provisioner rescue fallback), leave the fallback but ensure no non-config `agent_cmd: python_bin()` path remains. (FR-005)

**Checkpoint**: No back door; override preserved.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T016 [P] Append a status note to `docs/threat-model-agent-isolation.md`: generated agents now run inside the container sandbox (spec 044 / roadmap 11-01), closing the "no sandbox at all" gap; the Docker file-sharing trim (11-02) and runtime knob (11-03) remain follow-ups.
- [ ] T017 [P] Mark roadmap plan `11-01` progress in `.planning/ROADMAP.md` (leave 11-02/03/04 open).
- [x] T018 Run `mix format` + `mix credo` clean; ensure new/changed functions carry purpose docstrings and non-obvious blocks are commented (Constitution VII); `ruff` clean on the probe fixture.
- [ ] T019 Run the full regression: `mix test` (default, docker excluded) green, then `mix test --include docker` with Docker up — world-B (`world_b_test.exs`, `world_b_generated_test.exs`), `isolation_test.exs`, and the new containment/dispatch tests all green. (FR-010, SC-004)
- [ ] T020 Run [quickstart.md](quickstart.md) end-to-end (build image → jailed run → probe → induce each loud failure) as the manual acceptance walkthrough. (SC-001, SC-003, SC-005)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: T001, T002 — no dependencies, parallel.
- **Foundational (Phase 2)**: T003 depends on T001 (Dockerfile). Blocks all docker-tagged tests.
- **US1 (Phase 3)**: depends on Setup + Foundational. The MVP core.
- **US2 (Phase 4)**: depends on Foundational (image) and US1 dispatch (T008) to exercise the production path; the fixture (T011) can be authored in parallel with US1.
- **US3 (Phase 5)**: depends on US1 implementation (T007-T010) — it is the regression guard over the same code.
- **Polish (Phase 6)**: after US1-US3.

### Within US1 (same file — `run_worker.ex` — sequential)

- Tests T004, T005a, T005b, T006 first (must fail) → T007 (delete bypass) → T008 (image/mount/entrypoint selection + extract `dispatch_spec/3`) → T009 (discriminator) → T010 (pre-flight). T007-T010 all edit `run_worker.ex` and are **not** parallel with each other. T005a asserts on the `dispatch_spec/3` extracted by T008.

### Parallel Opportunities

- T001 ∥ T002 (different files).
- T004 ∥ T005a ∥ T005b ∥ T006 (test authoring, before implementation).
- T011 (fixture) ∥ US1 implementation.
- T013 ∥ T014; T016 ∥ T017.

---

## Parallel Example: Setup + US1 tests

```bash
# Phase 1 (parallel):
Task: "Create agents/generated.Dockerfile"
Task: "Add :agent_image / :generated_agent_image to config/config.exs"

# US1 test authoring (parallel, write-first):
Task: "Payload discriminator test in run_worker_transcript_test.exs"
Task: "Unit test dispatch_spec/3 in run_worker_dispatch_test.exs (no docker)"
Task: "@tag :docker end-to-end jailed-run test in generated_dispatch_test.exs"
Task: "Loud-failure tests (code_unmountable / image_unavailable / runtime_unavailable)"
```

---

## Implementation Strategy

### MVP (ships US1 + US2 together — both P1)

1. Phase 1 Setup → Phase 2 Foundational (image built).
2. US1: write failing tests → delete bypass → selection → discriminator → pre-flight.
3. US2: hostile fixture + containment probe green under Docker.
4. **STOP & VALIDATE**: quickstart §2-§3; world-B + isolation still green.

### Then

5. US3: no-back-door regression tests (guard against reintroduction).
6. Polish: threat-model/roadmap notes, format/credo/ruff, full regression, quickstart walkthrough.

---

## Notes

- `[P]` = different files, no incomplete-task dependency.
- Docker tests are `@tag :docker`, excluded by default — run with `--include docker`.
- The inference broker stays the deterministic stub (Constitution IV); no live model calls.
- Do not weaken any existing containment or gate behaviour (FR-010).
- Per project git rules: commits are the user's to trigger — leave changes in the working tree.
