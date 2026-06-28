# Tasks: Isolate the Discovery Agent

**Input**: Design documents from `specs/001-isolate-discovery-agent/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: INCLUDED — Constitution III mandates TDD for backend logic. Pure-function tests
(Sanitizer, Sandbox argv) are hermetic; in-container checks are tagged `:docker` and run the
deterministic stub agent (no live LLM, Constitution IV).

**Scope note (A1 decision)**: the agent reasoning stays a deterministic stub this phase, so
the container runs `--network none` (no egress, no proxy). The LLM egress allowlist is
deferred to whenever a real model is wired.

**Organization**: Grouped by user story. US1 is the MVP; US2 and US3 build on US1's
boundary but are independently testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1 / US2 / US3 (Setup, Foundational, Polish carry no story label)

---

## Phase 1: Setup (Shared Infrastructure)

- [x] T001 [P] Configure `ExUnit.configure(exclude: [:docker])` in `test/test_helper.exs` so the default `mix test` stays hermetic (Constitution IV); `mix test --include docker` runs the container suite.
- [x] T002 [P] Confirm `pydantic` is declared in `pyproject.toml` (add if missing) and run `uv sync`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ Blocks all user stories — every story runs the agent in a container.**

- [x] T003 Create the agent container image at `agents/discovery/Dockerfile` (`python:3.11-slim` + `uv`, copies agent code, runs as a non-root user, entrypoint reads stdin).
- [x] T004 [P] Add a dev helper script `scripts/agent_image.sh` that builds `agent-discovery:dev` (referenced by quickstart + `:docker` tests; does not run at test time).
- [x] T005 [P] Ensure the deterministic stub agent (`agents/discovery/main.py`) runs inside the image with `--network none`, for use by `:docker` tests.

**Checkpoint**: An image exists and can be launched; story work can begin.

---

## Phase 3: User Story 1 - Run the agent isolated from the host (Priority: P1) 🎯 MVP

**Goal**: The discovery agent executes inside a sandbox separate from the host; it cannot
reach host resources, credentials, or substrate state beyond its granted input/output, and
has no network at all.

**Independent Test**: Run the agent (stub) through its normal path; from outside, confirm
out-of-grant filesystem access and any outbound network both fail, while granted
input/output and `/scratch` work.

### Tests for User Story 1 (write first, must FAIL)

- [x] T006 [P] [US1] Unit test the docker-argv builder in `test/agent_os/sandbox_test.exs`, asserting it emits `--network none`, `--read-only`, `--tmpfs /scratch`, `--memory`/`--memory-swap`, `--cpus`, `--user`, `--cap-drop ALL`, `--security-opt no-new-privileges`, and `--cidfile` (per `contracts/sandbox.md`).
- [x] T007 [P] [US1] Integration test `test/agent_os/isolation_test.exs` (tag `:docker`): stub writing to `/scratch` succeeds; reading a host path outside `/scratch` fails; any outbound network connection fails.

### Implementation for User Story 1

- [x] T008 [P] [US1] Implement `AgentOS.Sandbox` (struct + pure argv builder) in `lib/agent_os/sandbox.ex` per `contracts/sandbox.md`.
- [x] T009 [US1] Modify `lib/agent_os/port_runner.ex` to invoke `cmd = "docker"` with the `Sandbox` argv instead of `python` (reuse the exit-status path unchanged).
- [x] T010 [US1] Extend `priv/port_wrapper.sh` to pass `--cidfile` and `trap EXIT` → `docker stop` then `docker kill` the recorded id, so no container is orphaned on timeout/crash (D2).
- [x] T011 [US1] Wire `lib/agent_os/provisioner.ex` / `lib/agent_os/run_worker.ex` to build and pass the discovery agent's `Sandbox` config (hard-wired grants, consistent with Phase 1 provisioning).
- [x] T012 [US1] Add logging of container start (image, resource caps, `--network none`) in `lib/agent_os/sandbox.ex` (Constitution VI).

**Checkpoint**: US1 fully functional and independently testable — the MVP.

---

## Phase 4: User Story 2 - Safe against hostile web input (Priority: P2)

**Goal**: Untrusted bookmark content (prompt-injection or malformed) cannot break
isolation, exfiltrate, or corrupt state; it is validated and bounded before the agent
reasons over it.

**Independent Test**: Feed a crafted hostile bookmark fixture; confirm no out-of-grant
action, no escape, and a safe, logged outcome.

### Tests for User Story 2 (write first, must FAIL)

- [x] T013 [P] [US2] Unit test `AgentOS.Sanitizer` in `test/agent_os/sanitizer_test.exs`: size bounds, control-char stripping, schema rejection, and drop-and-log of malformed items (per data-model.md rules).
- [x] T014 [P] [US2] Python test for the Pydantic input model + rejection of malformed input in `agents/discovery/test_main.py`.
- [x] T015 [P] [US2] Integration test (tag `:docker`) in `test/agent_os/isolation_test.exs`: hostile fixture (injection text + malformed payload) → no out-of-grant action, no escape, run fails safely and is logged.

### Implementation for User Story 2

- [x] T016 [P] [US2] Implement `AgentOS.Sanitizer` in `lib/agent_os/sanitizer.ex` (validate → bound → normalize → drop+log rejects).
- [x] T017 [P] [US2] Implement the Pydantic input model in `agents/discovery/models.py`.
- [x] T018 [US2] Modify `agents/discovery/main.py` to validate input via `models.py` before reasoning; exit non-zero with a stderr log on invalid input.
- [x] T019 [US2] Modify `lib/agent_os/provisioner.ex` to load the bookmark export fixture, run it through `Sanitizer`, and pass the sanitized items (alongside the agent's mounted-state snapshot) across the boundary.
- [x] T020 [P] [US2] Add a hostile bookmark fixture at `test/fixtures/hostile_bookmarks.json` for the integration test.

**Checkpoint**: US1 + US2 both work independently.

---

## Phase 5: User Story 3 - Failures surface cleanly and operation stays legible (Priority: P3)

**Goal**: A container crash or OOM surfaces to the BEAM supervisor as a clean exit so
restart-once-and-alert keeps working; every run (incl. failures + cause) is legible in the
run-log and inventory; the agent is runnable unattended on the timer and on demand.

**Independent Test**: Force a crash and an OOM; confirm clean-exit surfacing, restart-once-
and-alert, and legible run-log/inventory entries; confirm both the daily timer and a manual
trigger launch the sandboxed run and are recorded.

### Tests for User Story 3 (write first, must FAIL)

- [x] T021 [P] [US3] Integration test (tag `:docker`): forced crash (`exit 1`) → `:failed`; forced OOM (exceed `--memory`) → exit `137` surfaced; restart-once-and-alert fires.
- [x] T022 [P] [US3] Unit test exit-code classification in `test/agent_os/run_worker_test.exs` (0→ok, 137→oom, other→crash, timeout→timeout).
- [x] T023 [P] [US3] Test the manual on-demand path records `trigger: :manual` in `test/agent_os/scheduler_test.exs`.
- [x] T024 [P] [US3] Test that the daily timer trigger launches the sandboxed run and records `trigger: :timer` in `test/agent_os/scheduler_test.exs` (FR-007 / SC-005 — closes the timer→container coverage gap).

### Implementation for User Story 3

- [x] T025 [US3] Modify `lib/agent_os/run_worker.ex` to classify the container exit code into outcome + cause and attach it to the Run Record.
- [x] T026 [US3] Extend the Run Record in `lib/agent_os/run_log.ex` and `lib/agent_os/inventory.ex` with `exit_code`, `failure_cause`, `items_in`/`items_dropped`, and `trigger` (FR-006).
- [x] T027 [US3] Add `AgentOS.Scheduler.run_now(:manual)` in `lib/agent_os/scheduler.ex` for the on-demand run, and ensure the daily timer path tags `trigger: :timer` (FR-010 / FR-007).
- [x] T028 [US3] Confirm restart-once-and-alert fires on OOM/crash across the boundary by wiring `lib/agent_os/run_supervisor.ex` / `lib/agent_os/alerter.ex` to the classified failure.
- [x] T029 [US3] Add run-log entries for exit cause and sanitizer drop counts (Constitution VI / FR-006).

**Checkpoint**: All three stories independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T030 [P] Run `quickstart.md` validation end-to-end (build image, manual run, full `mix test --include docker` green).
- [x] T031 [P] Verify `docker ps` is clean after a timeout/crash (no orphaned containers) and the container has no network (`--network none`).
- [x] T032 Quality gates: `mix format` + Credo clean (Elixir), `ruff` + `mypy` clean (Python).
- [x] T033 [P] Update `data/run_log.md` / inventory docs so failure legibility is demonstrable.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (P1)**: no dependencies.
- **Foundational (P2)**: after Setup. Blocks all stories (image must exist).
- **US1 (P3)**: after Foundational. The MVP; US2 and US3 build on its boundary.
- **US2 (P4)**: after US1 (uses the boundary), but independently testable.
- **US3 (P5)**: after US1 (needs the container exit path); independently testable.
- **Polish (P6)**: after the desired stories.

### Within each story

- Tests (T006/T007, T013–T015, T021–T024) written first and FAIL before implementation.
- Sandbox/Sanitizer modules before the modules that wire them in.

### Parallel opportunities

- Setup: T001, T002 in parallel.
- Foundational: T004, T005 in parallel after T003.
- US1: T006 ∥ T007 (tests); T008 ∥ T010 (different files) before T009/T011.
- US2: T013 ∥ T014 ∥ T015 (tests); T016 ∥ T017 ∥ T020 before T018/T019.
- US3: T021 ∥ T022 ∥ T023 ∥ T024 (tests).

---

## Implementation Strategy

### MVP first (US1 only)

1. Setup → Foundational → US1.
2. **STOP and validate**: the agent runs sandboxed; out-of-grant filesystem access and any outbound network both fail; `mix test --include docker` green for isolation.
3. This alone delivers the core safety property — the agent that ran in the host's trust context now runs contained.

### Incremental delivery

- Add US2 → hostile input is safe → validate.
- Add US3 → failures surface cleanly + legibly, timer + manual runs work → validate.
- Each increment leaves the previous green.

---

## Notes

- `[P]` = different files, no incomplete-task dependency.
- `:docker` tests require Docker; the default suite excludes them (T001) to stay hermetic.
- Docker commands (build/run) are executed with the operator's approval (project rule); these tasks *write* the configuration and code, runs happen at test/validation time.
- Commit after each task or logical group (with explicit permission, per project rule).
