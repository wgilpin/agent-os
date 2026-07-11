# Implementation Plan: Containerize the Substrate for Cross-Container Inference

**Branch**: `045-containerize-substrate-uds` | **Date**: 2026-07-11 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/045-containerize-substrate-uds/spec.md`

## Summary

Sandboxed agents on macOS get `ECONNREFUSED` connecting to the inference broker's Unix
socket: the BEAM broker listens on the macOS host kernel (`mix`) while agent containers run
in OrbStack's Linux VM kernel. A bind-mount shares the socket's *file node*, not its
*listening endpoint*. Fix: run the BEAM substrate as a container in the same OrbStack VM,
with the inference socket on a **shared named volume** (`aos_inf`) mounted at the identical
path (`/run/aos`) in the substrate container and every agent container. Selected by a new
`:inference_socket_volume` config key; when unset, every code path behaves byte-for-byte as
today (host-bind mode). The change is additive: host `mix test` stays hermetic and green with
no new requirement, and a documented `docker compose` entry point runs the docker-tagged
suite with the substrate in-VM.

## Amendment (2026-07-11): container-only substrate

The original plan made the container an *option* alongside a host run. The amendment
(spec US3 rewrite + new US4, FR-011/012/013, SC-006/007) makes the **containerized substrate the
sole way to run the app** — host app start is eliminated as an operable state, and the container
must do everything the host did, including the LiveView web UI. The host-bind topology survives
only inside the hermetic test suite (autostart disabled). Delta decisions:

- **A1 — Boot guard (FR-011/SC-007)**: `AgentOS.Application.start/2` calls a `boot_guard!/0` that
  delegates to a pure `boot_permitted?(autostart?, in_container?, os_type)`. It refuses ONLY the
  broken topology — autostart enabled **and** not in-container (`AOS_IN_CONTAINER` unset) **and**
  `:os.type() == {:unix, :darwin}` — raising a loud message naming `docker compose up substrate`.
  Everything else (`autostart?` false = the test suite; in-container; non-macOS host) is permitted.
  The pure function is unit-tested directly so the refusal is proven without aborting the test VM.
- **A2 — LiveView from the host browser (FR-012/SC-006)**: the endpoint binds loopback on the host
  but `0.0.0.0:4000` in-container. A container-mode block in `config/config.exs` (gated on
  `AOS_IN_CONTAINER`, skipped in `:test` where the server is disabled) sets the all-interfaces
  bind; compose publishes `4000:4000`. Config is evaluated at compile time in-container, where
  `AOS_IN_CONTAINER` is set, so the bind resolves for `mix run --no-halt`.
- **A3 — Shared-volume mode in every env in-container (FR-013)**: the shared-volume config
  selection moves out of the `:test`-only block into a global `AOS_IN_CONTAINER` block, so the full
  dev app (not just the test suite) reaches its agents over `aos_inf`. The prior test-block
  duplicate is removed (single source).
- **A4 — Compose restructure (FR-012/FR-008)**: `substrate` becomes a long-running app service
  (`MIX_ENV=dev`, `mix run --no-halt`, `ports: 4000:4000`); a second `e2e` service shares the image
  and volumes (`MIX_ENV=test`, `mix deps.get && mix test --only docker`). Common build/mounts/env
  live in YAML anchors. The `aos_inf` volume stays pinned to `name: aos_inf` (sibling dispatch
  breaks without it). MODEL_KEY passthrough is preserved on both services.
- **A5 — Everything-in-container (FR-013)**: the elicitor (host-port Python workload via
  `PortRunner`, `PYTHON_BIN`) runs against the baked `/opt/aos/venv`, which already covers its only
  dep (`pydantic`) — no Dockerfile change needed. Repo-local `data/` persistence is the identical
  bind mount used for code, verified writable in-container.

## Technical Context

**Language/Version**: Elixir 1.20.2 on Erlang/OTP 29 (control plane); Python 3.11 (sandboxed agent workloads only)
**Primary Dependencies**: OTP `:gen_tcp` (UDS listener), `exqlite` (NIF — needs a C toolchain in the substrate image), OrbStack Docker daemon
**Storage**: term-file StateStores + git-backed markdown (unchanged by this feature)
**Testing**: ExUnit; docker-tagged suites excluded by default (`ExUnit.start(exclude: [:docker])`)
**Target Platform**: macOS + OrbStack for shared-volume mode; Linux host / unit tests keep host-bind mode
**Project Type**: Single Elixir/OTP application (`lib/agent_os/`) with Python port workloads (`agents/<name>/`)
**Performance Goals**: N/A (topology/connectivity fix, not a perf change)
**Constraints**: No change to generation, judging, or spend semantics; UDS path ≤ ~104 chars; sandbox invariant (one writable mount, rest `:ro`) preserved
**Scale/Scope**: 5 source touch points + 1 config block + 2 new container files + 1 test-harness branch + tests. No new runtime dependency.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Simplicity First** — PASS. Reuses the existing single sandbox/dispatch path; adds one
  config key and a mode branch in four functions. No new library, no abstraction layer. The
  compose service exists only for real runs and the docker-tagged suite; the host `mix`
  workflow is untouched.
- **II. Explicit Scope Control** — PASS. Scope is exactly the socket mount source/path,
  socket permissions, the substrate container, and the test entry point. 044 dispatch logic,
  vsock/per-agent VMs (11-04), and spend semantics are explicitly out of scope.
- **III. Test-Driven Backend** — PASS. New backend branches (`build_argv` mode selection,
  broker permission mode, dispatch mount source) get unit tests first; the cross-container E2E
  is the integration proof.
- **IV. No Live Dependencies in Tests** — PASS. The generated-agent broker E2E uses
  `start_broker_uds!/1` with a **stubbed** `provider_fn` (no live model). A real model call
  (SC-001) is a manual/operator step, never an automated test.
- **V. Strong Typing, No Bare Maps** — PASS. `dispatch_spec/3` keeps its typed map return; new
  config reads are typed; no bare-map surface added.
- **VI. Loud Failures** — PASS. FR-009: socket-absent / permission-denied / volume-missing /
  daemon-unreachable all fail loudly with a diagnosable cause and never fall back to a host run.
  The broker already logs GID/reason on chgrp failure; we extend, not weaken, that.
- **VII. Self-Documenting** — PASS. Every new/modified function carries a purpose comment
  explaining the mode branch and *why* (cross-kernel UDS).
- **VIII–XII (Architectural invariants)** — PASS / untouched. The substrate still owns state and
  lifecycle; the gate/manifest/authority model is unchanged; enforcement-before-generation
  ordering is irrelevant here (no generation change). No agent-domain vocabulary enters
  `lib/agent_os/` (the volume name/path are substrate infra config, not any agent's concept).

No violations. Complexity Tracking table left empty.

## Project Structure

### Documentation (this feature)

```text
specs/045-containerize-substrate-uds/
├── plan.md              # This file
├── research.md          # Phase 0 — resolved design decisions
├── data-model.md        # Phase 1 — config/entity model (socket topology mode)
├── quickstart.md        # Phase 1 — how to run the containerized substrate + docker suite
├── contracts/
│   └── socket-topology.md   # The two-mode config contract + compose entry-point contract
└── tasks.md             # Phase 2 (/speckit-tasks) — NOT created here
```

### Source Code (repository root)

```text
Dockerfile                       # NEW — substrate image: Elixir 1.20.2/OTP 29 + docker CLI + build toolchain + venv
docker-compose.yml               # NEW — substrate (app, MIX_ENV=dev, 4000:4000) + e2e (test) services; aos_inf pinned
config/config.exs                # +:inference_socket_volume; container-mode block: shared-volume (all envs) + 0.0.0.0:4000 (dev)
mix.exs                          # env-driven deps_path/build_path so container artifacts never clash with host _build
lib/agent_os/application.ex      # AMENDMENT — boot guard: boot_permitted?/3 refuses host app start on macOS (FR-011)
lib/agent_os/run_worker.ex       # dispatch_spec/3 mount source + INFERENCE_SOCKET env → mode branch
lib/agent_os/sandbox.ex          # build_argv/1 writable-mount validation → mode branch
lib/agent_os/inference_broker.ex # start_uds_listener/1 dir 0770 + chgrp in volume mode; 0700 in bind mode
test/test_helper.exs             # start_broker_uds!/1 → per-test socket under the shared volume when in-container
test/agent_os/isolation_test.exs # hostile-web E2E runs with substrate in-VM (existing :docker test)
test/agent_os/application_boot_guard_test.exs # AMENDMENT — NEW unit test for boot_permitted?/3 refusal logic
test/agent_os/*_test.exs         # NEW unit tests for mode branches; NEW generated-agent broker E2E (:docker)
```

**Structure Decision**: Single Elixir/OTP app. The feature adds two container-infra files at
the repo root and threads one config key (`:inference_socket_volume`) through four existing
functions plus the test harness. No new module or directory in `lib/`; the mode branch lives
where the socket path/mount/permission decisions already are.

## Complexity Tracking

> No Constitution violations — table intentionally empty.
