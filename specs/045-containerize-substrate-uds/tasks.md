# Tasks: Containerize the Substrate for Cross-Container Inference

**Input**: Design documents from `/specs/045-containerize-substrate-uds/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/socket-topology.md, quickstart.md

**Tests**: Included. Constitution III (Test-Driven Backend) applies — the new backend mode
branches are built test-first. No live-model tests (Constitution IV): the E2E uses a stubbed
`provider_fn`; the real model call (SC-001) is a manual operator step.

**Organization**: Grouped by user story. US1 = the cross-container inference plumbing (code
mode branches). US2 = the containerized proof harness (substrate image, compose, docker E2E).
US3 = host-workflow regression proof.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no incomplete dependencies)
- Paths are repository-root relative; the project is a single Elixir/OTP app.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Introduce the mode-selection config and isolate container build artifacts. Both are
inert until a volume is configured (SC-004).

- [X] T001 Add `:inference_socket_volume` (default `nil`) and `:inference_socket_volume_path`
  (default `"/run/aos"`) to the `config :agent_os` block in `config/config.exs`, with a comment
  explaining host-bind vs shared-volume mode (Constitution VII). Do NOT set them in the `:test`
  block (host unit tests stay in bind mode).
- [X] T002 Make `deps_path`/`build_path` env-driven in `mix.exs` `project/0`:
  `deps_path: System.get_env("MIX_DEPS_PATH") || "deps"` and
  `build_path: System.get_env("MIX_BUILD_PATH") || "_build"`, so container-local artifacts never
  clash with the host `_build` (research D7). Host `mix` (env unset) keeps the defaults.

**Checkpoint**: `mix compile` and `mix test` still green on the host; new keys default to nil/`/run/aos`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: A single source of truth for mode derivation, consumed by all four call sites
(contract §1: no second switch).

- [X] T003 [P] Write `test/agent_os/inference_topology_test.exs`: `mode/0` returns `:host_bind`
  when `:inference_socket_volume` is nil and `:shared_volume` when set; `volume_name/0` and
  `volume_path/0` return the configured values in shared mode.
- [X] T004 Create `lib/agent_os/inference_topology.ex` (`AgentOS.InferenceTopology`) exposing
  `mode/0`, `volume_name/0`, `volume_path/0`, all derived from `:inference_socket_volume` /
  `:inference_socket_volume_path`, with `@moduledoc`/`@doc` and typespecs (Constitution V/VII).

**Checkpoint**: Topology helper green; no behaviour change with nil volume.

---

## Phase 3: User Story 1 - Sandboxed agent reaches the model (P1)

**Goal**: In shared-volume mode the agent's inference mount is the named volume, its
`INFERENCE_SOCKET` points at the in-volume socket, the sandbox permits exactly that one writable
mount, and the broker makes the socket group-reachable — so the agent connects and completes a
model call (FR-002/004/005/006).

**Independent Test**: SC-001 — a real generated agent completes a run with ≥1 successful model
call from inside its sandbox (manual operator run via the substrate container, needs a live key).
Automated coverage below proves each branch deterministically.

### Tests for User Story 1 (write first — must fail before impl)

- [X] T005 [P] [US1] In `test/agent_os/generated_dispatch_test.exs` (or a new
  `dispatch_topology_test.exs`), assert `RunWorker.dispatch_spec/3` in shared-volume mode returns
  the inference mount `{"aos_inf", "/run/aos"}` (not a host path) and that the generated-agent
  code mount `{code_dir, ".../<name>:ro"}` is unchanged (FR-010 parity); and in bind mode returns
  today's `{Path.expand(uds_path), "/tmp/inference.sock"}`.
- [X] T006 [P] [US1] Add tests to `test/agent_os/sandbox_test.exs`: in shared-volume mode
  `build_argv/1` accepts a writable mount whose target == `volume_path` and source == `volume_name`
  and rejects any other writable (non-`:ro`) mount; in bind mode the existing path-equality check
  is unchanged. Cover the raise messages (FR-005/FR-009).
- [X] T007 [P] [US1] Add a test asserting the agent `INFERENCE_SOCKET` env equals the full
  configured `:inference_uds_path` in shared-volume mode and `/tmp/inference.sock` in bind mode
  (assert against the `opts_with_env`/dispatch env surface exercised in the run_worker tests).

### Implementation for User Story 1

- [X] T008 [US1] In `lib/agent_os/run_worker.ex` `dispatch_spec/3` (~line 296): branch on
  `InferenceTopology.mode/0`. Shared-volume ⇒ `inference_mount = {volume_name, volume_path}`; bind
  ⇒ unchanged `{Path.expand(uds_path), "/tmp/inference.sock"}`. Keep the generated-agent `:ro`
  code mount identical in both (FR-010).
- [X] T009 [US1] In `lib/agent_os/run_worker.ex` (~lines 162-188): set the container
  `INFERENCE_SOCKET` env to the full `:inference_uds_path` in shared-volume mode, keeping
  `/tmp/inference.sock` in bind mode. Update both the default-env and the `Keyword.update` env
  branches so they agree.
- [X] T010 [US1] In `lib/agent_os/sandbox.ex` `build_argv/1` (~lines 89-106): branch the
  writable-mount validation on `InferenceTopology.mode/0` per contract §3 — shared-volume enforces
  target==`volume_path` & source==`volume_name`; bind keeps the host-path-equality check. Preserve
  loud `ArgumentError` messages (FR-005/FR-009).
- [X] T011 [US1] In `lib/agent_os/inference_broker.ex` `start_uds_listener/1` (~line 569): in
  shared-volume mode chmod the socket's parent dir to `0o770` and `:file.change_group` it to the
  configured GID (socket stays `0660`+chgrp); bind mode keeps `0o700` and no dir chgrp. Extend the
  existing loud error/log paths (FR-006/FR-009, SC-005).

**Checkpoint**: US1 unit tests green in BOTH modes; `mix test` on host still green (bind mode).

---

## Phase 4: User Story 2 - Docker-tagged inference E2E tests pass (P2)

**Goal**: A documented `docker compose` command runs the docker-tagged suite with the substrate
in the OrbStack VM; the hostile-web isolation E2E and a new generated-agent broker E2E pass over
the shared-volume socket (FR-001/007/008, SC-002).

**Independent Test**: `docker compose run --rm substrate mix test --include docker` exits 0.

### Tests for User Story 2

- [X] T012 [P] [US2] Add a `@tag :docker` generated-agent broker E2E (new
  `test/agent_os/generated_broker_e2e_test.exs`): via `start_broker_uds!/1` with a **stubbed**
  provider, dispatch a real generated agent container that connects to the shared-volume socket
  and receives a completion — asserting no `ECONNREFUSED` and a recorded tool-call/inference
  result (FR-002, Acceptance US1.1). Skips/guards cleanly when not in-container.

### Implementation for User Story 2

- [X] T013 [US2] Create `Dockerfile` (substrate image): base on a `hexpm/elixir` tag matching
  Elixir 1.20.2 / OTP 29 (Debian); `apt-get install` `docker-ce-cli` + `build-essential` (for the
  `exqlite` NIF); set `WORKDIR /Users/will/projects/agent_os`; no `ENTRYPOINT` (command supplied by
  compose). Purpose comment per Constitution VII. Verify by building.
- [X] T014 [US2] Create `docker-compose.yml`: `substrate` service `build: .`; volumes
  `aos_inf:/run/aos`, `/var/run/docker.sock:/var/run/docker.sock`, and the repo at the identical
  path `/Users/will/projects/agent_os:/Users/will/projects/agent_os`; env `INFERENCE_GID=1000`,
  `AOS_IN_CONTAINER=1`, `MIX_ENV=test`, `MIX_DEPS_PATH=/opt/aos/deps`, `MIX_BUILD_PATH=/opt/aos/_build`,
  model-key passthrough; declare the `aos_inf` named volume; default command
  `sh -c "mix deps.get && mix test --include docker"` (FR-007/008, research D5-D8).
- [X] T015 [US2] In `test/test_helper.exs` `start_broker_uds!/1` (~line 176): when
  `System.get_env("AOS_IN_CONTAINER")` is set, create the per-test socket under the shared volume
  (`/run/aos/test_<uniq>/inf.sock`) and configure shared-volume mode
  (`:inference_socket_volume`, `:inference_socket_volume_path`, `:inference_uds_path`) for the test,
  restoring all on exit; otherwise keep today's `System.tmp_dir!()` bind-mode behaviour (FR-008,
  Acceptance US2.2 per-test isolation).
- [X] T016 [US2] Ensure the existing hostile-web isolation E2E
  (`test/agent_os/isolation_test.exs:83`) runs under the containerized substrate; adjust only what
  the topology requires (no logic change to the test's assertions).
- [X] T017 [US2] Build the image and run `docker compose run --rm substrate mix test --include
  docker`; confirm the hostile-web E2E and the new generated-agent broker E2E pass (SC-002).
  Record the exact command in `quickstart.md` (already present) and reference it from a comment in
  `docker-compose.yml`.

**Checkpoint**: Docker-tagged suite green in-VM via the one documented command.

---

## Phase 5: User Story 3 - Host development workflow unchanged (P3)

**Goal**: Prove the feature is additive — the default host suite is green with zero new host
requirement, and bind-mode behaviour is byte-for-byte unchanged (SC-003/SC-004).

**Independent Test**: `mix test` on the host passes with no container involvement.

- [X] T018 [US3] Run `mix test` on the host; confirm green with docker tests excluded by default
  and no new host-side requirement (SC-003). Fix ALL failures, feature-related or not (project rule).
- [X] T019 [US3] Confirm bind-mode invariance (SC-004): existing `sandbox_test.exs`,
  `generated_dispatch_test.exs`, `generated_containment_test.exs`, and broker/UDS suites pass
  unchanged with `:inference_socket_volume` unset (no behavioural diff vs pre-feature).

**Checkpoint**: Host workflow provably unchanged.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T020 [P] Run `mix format` and `mix credo` (Elixir quality gates); resolve findings in the
  touched files.
- [X] T021 [P] Verify all new/changed functions carry purpose comments/`@doc` and the mode
  branches are commented with the *why* (cross-kernel UDS) per Constitution VII.
- [X] T022 Final full check: host `mix test` green AND `docker compose run --rm substrate mix test
  --include docker` green; note the live SC-001 run (real key) as the remaining operator step.

---

## Phase 7: Amendment — container-only substrate (US3 rewrite, US4)

**Purpose**: Make the containerized substrate the SOLE run mode — refuse host app start, and make
the container do everything including the LiveView web UI (FR-011/012/013, SC-006/007). Host-bind
survives only in the hermetic test suite. Existing completed tasks (T001-T022) are unchanged.

- [X] T023 [US3] Boot guard (FR-011/SC-007) in `lib/agent_os/application.ex`: add
  `boot_permitted?/3` (pure: refuses only autostart + not-in-container + `{:unix, :darwin}`; permits
  all else) and a `boot_guard!/0` called first in `start/2` that logs+raises the refusal naming
  `docker compose up substrate`. Autostart-disabled (test) and in-container starts unaffected.
- [X] T024 [P] [US3] Unit test `test/agent_os/application_boot_guard_test.exs`: `boot_permitted?/3`
  refuses `(true,false,{:unix,:darwin})` with a message naming the container entry point; permits
  in-container, autostart-off, and non-macOS — proving the refusal without aborting the test VM.
- [X] T025 [US4] LiveView host-browser bind (FR-012/SC-006) in `config/config.exs`: a container-mode
  block (gated on `AOS_IN_CONTAINER`, skipped in `:test`) binds the endpoint `0.0.0.0:4000`; host
  stays loopback. Move the shared-volume config selection to the same global block so the full dev
  app (FR-013), not just the test suite, runs shared-volume mode; remove the test-block duplicate.
- [X] T026 [US4] Compose restructure (FR-012/FR-008) in `docker-compose.yml`: `substrate` = the
  long-running app service (`MIX_ENV=dev`, `mix run --no-halt`, `ports: 4000:4000`); new `e2e`
  service shares the image/volumes (`MIX_ENV=test`, `mix deps.get && mix test --only docker`).
  Common build/mounts/env in YAML anchors; `aos_inf` stays pinned to `name: aos_inf`; MODEL_KEY
  passthrough preserved on both.
- [X] T027 [US4] Everything-in-container (FR-013): confirm the elicitor runs in-container via
  `PYTHON_BIN=/opt/aos/venv/bin/python` against the baked venv (its only dep `pydantic` is covered —
  no Dockerfile change) and repo-local `data/` persists via the bind mount. Verified: elicitation
  suite green in-container; broker on `/run/aos/inference.sock`; `data/*.db` writable to the tree.
- [X] T028 [US4] Docs: `README.md` (Running the app / Running the suites), `quickstart.md`, and
  `contracts/socket-topology.md` §6 — `docker compose up substrate` is THE app entry, `docker
  compose run --rm e2e` is the E2E entry, host start documented as refused. No host app-start
  instructions reintroduced.
- [X] T029 [US4] Verify: host `mix test` green (531 passed, 14 excluded — boot guard doesn't break
  tests); `mix run --no-halt` on the host mac refuses with exit 1 + loud message;
  `docker compose build substrate` + `docker compose run --rm e2e` = 14/14; `docker compose up -d
  substrate` + host `curl http://localhost:4000/` = HTTP 200 with LiveView markup; elicitor smoke
  in-container green. Full browser websocket interaction left to the operator.

## Dependencies & Execution Order

- **Setup (T001-T002)** → blocks everything.
- **Foundational (T003-T004)** → blocks US1/US2 (all sites derive mode from the helper).
- **US1 (T005-T011)** → the code plumbing; unit-testable on the host in both modes. MVP core.
- **US2 (T012-T017)** → depends on US1 code (the mode branches it exercises) + Foundational;
  delivers the containerized proof and the automated E2E for SC-002.
- **US3 (T018-T019)** → runnable after US1 lands (regression); independent of US2.
- **Polish (T020-T022)** → last.

Within a phase, `[P]` tasks touch different files and may run in parallel. T008/T009 share
`run_worker.ex` (sequential); T010 (`sandbox.ex`) and T011 (`inference_broker.ex`) are `[P]`
relative to each other.

## Implementation Strategy

- **MVP** = Setup + Foundational + US1: the cross-container plumbing, unit-proven in both modes.
- **Proof** = US2: containerize and run the docker-tagged E2E (SC-002) — the regression guard.
- **Guard** = US3: host suite green + bind-mode invariance (SC-003/SC-004).
- **Left for operator**: the live SC-001 run with a real model key (Constitution IV keeps it out
  of the automated suite).
