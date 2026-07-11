# Phase 0 Research: Containerize the Substrate

All open decisions from `docs/substrate-containerization-analysis.md` are resolved by the
approved plan (`.claude/plans/what-is-the-solution-snazzy-floyd.md`). Recorded here as
Decision / Rationale / Alternatives so the plan is self-contained.

## D1 — Shared named volume, not a host bind directory

- **Decision**: Put the inference socket on a Docker **named volume** `aos_inf`, mounted at the
  identical path `/run/aos` in the substrate container and every agent container. Socket lives
  under that path (default `/run/aos/inference.sock`).
- **Rationale**: A named volume lives entirely inside the OrbStack Linux VM, so both endpoints
  share one kernel — the empirically-proven topology (two VM containers over a shared socket
  volume → `CONNECTED`). A macOS host bind dir would re-cross the kernel boundary and reproduce
  the original `ECONNREFUSED`.
- **Alternatives**: Host bind dir for the socket — rejected (reintroduces the cross-kernel bug).
  vsock — out of scope (roadmap 11-04, per-agent hardware VMs).

## D2 — Mode selected by `:inference_socket_volume` (nil ⇒ current behaviour)

- **Decision**: New config `:inference_socket_volume` (string volume name, e.g. `"aos_inf"`;
  `nil` default) plus `:inference_socket_volume_path` (container mount dir, default `/run/aos`).
  `nil` volume ⇒ **host-bind mode** = today's behaviour, byte-for-byte. Non-nil ⇒
  **shared-volume mode**.
- **Rationale**: One switch, read where the socket path/mount/permission decisions already are.
  Satisfies FR-003 and SC-004 (no volume ⇒ identical observable behaviour) with the smallest
  possible surface (Constitution I).
- **Alternatives**: A separate boolean flag + implicit path — rejected; the volume name is the
  natural presence-signal and carries the value dispatch needs.

## D3 — Volume mount dir is fixed; socket may sit in a subdir

- **Decision**: In volume mode the agent mounts `{volume_name, volume_path}` (e.g.
  `{"aos_inf", "/run/aos"}`) and `INFERENCE_SOCKET` = the full configured `:inference_uds_path`
  (which lives under `volume_path`, e.g. `/run/aos/inference.sock` or, for a test,
  `/run/aos/test_<uniq>/inf.sock`). The mount target is always `volume_path`, independent of the
  socket's subpath.
- **Rationale**: Lets the test harness give each test its own socket **under one shared volume**
  (FR-008) while keeping a single, stable writable mount for the sandbox invariant. The volume
  root `/run/aos` is world-traversable (0755 root) so agents reach a 0770 group-owned subdir.
- **Alternatives**: Derive the mount dir from `Path.dirname(socket)` — rejected; per-test subdir
  sockets would each demand their own mount, breaking the single-writable-mount invariant.

## D4 — Socket permissions: 0770 dir + chgrp in volume mode; 0700 unchanged in bind mode

- **Decision**: In volume mode `start_uds_listener/1` chmods the socket's parent dir to `0770`
  and `chgrp`s it (and keeps the socket at `0660` + chgrp) to the configured `INFERENCE_GID`. In
  host-bind mode the dir stays `0700` and no dir chgrp — exactly as today.
- **Rationale**: The agent runs `1000:<inference_gid>`; a 0770 group-owned dir + 0660 group-owned
  socket grants that group connect/read while excluding others (FR-006, SC-005). The earlier
  `chgrp … :eperm` was a **macOS-host** limitation (unprivileged host process can't chgrp to an
  arbitrary GID); the substrate container runs the BEAM as **root**, so chgrp succeeds. Using
  `INFERENCE_GID=1000` aligns the socket group with the agent image's `app` group (gid 1000), so
  access works via the agent's primary group.
- **Alternatives**: World-accessible socket (0777/0666) — rejected (SC-005 requires exclusion of
  other users). Keep 0700 — rejected (agent's group could not traverse/connect cross-container).

## D5 — Dev workflow: host `mix` stays default; a compose service runs the substrate in-VM

- **Decision**: Host `mix test` is unchanged and remains the default hermetic loop. A new
  `docker-compose.yml` `substrate` service builds the substrate image and runs real agent runs
  and `docker compose run --rm substrate mix test --include docker`.
- **Rationale**: Additive (User Story 3 / SC-003): developers who don't run docker-tagged tests
  need nothing new. Only the docker suite and real macOS runs require the container.

## D6 — Substrate container mounts docker.sock and the repo at the identical host path

- **Decision**: The substrate service mounts `/var/run/docker.sock` (spawn **sibling** agent
  containers via the VM daemon) and bind-mounts the repo at the **identical absolute host path**
  `/Users/will/projects/agent_os`, set as `working_dir`.
- **Rationale**: Generated-agent code mounts are `Path.expand("agents/<name>")` = a host path
  (`run_worker.ex:314`). A sibling `docker run -v <host_path>:…:ro` is resolved by the VM daemon
  against the host filesystem OrbStack shares in; the substrate must therefore *see* the repo at
  that same path so `Path.expand` computes the correct source (FR-007). Different path ⇒ broken
  sibling mounts ⇒ fail loudly (spec edge case).
- **Alternatives**: `docker-in-docker` (nested daemon) — rejected (heavier, and siblings couldn't
  see host paths). Path translation layer — rejected (Constitution I; identical path needs none).

## D7 — Container build artifacts must not clash with the host `_build`

- **Decision**: The repo is bind-mounted live (so the container tests current source), but
  `mix.exs` reads `MIX_DEPS_PATH` / `MIX_BUILD_PATH` from the environment; the compose service
  points them at container-local dirs (e.g. `/opt/aos/deps`, `/opt/aos/_build`). The service
  runs `mix deps.get && mix test --include docker`.
- **Rationale**: The host `_build`/`deps` hold **macOS**-compiled BEAM/NIF artifacts that won't
  run in the Linux VM; sharing them would break the container run and could corrupt the host
  tree. Redirecting to container-local paths keeps Linux artifacts isolated and leaves the host
  tree (and host `mix test`) byte-for-byte unchanged (SC-003/SC-004). When the env vars are
  unset (host workflow), `mix.exs` falls back to the defaults `deps` / `_build`.
- **Alternatives**: Bake a full `mix compile` into the image and mount only subdirs as siblings —
  rejected (image rebuild per source change; slow iteration). Mount repo read-only — rejected
  (`mix` needs to write compiled artifacts; redirecting the paths is simpler than curating a ro
  overlay).

## D8 — Substrate base image

- **Decision**: Base on a `hexpm/elixir` tag matching Elixir 1.20.2 / OTP 29 on Debian, then
  `apt-get install` the Docker CLI (`docker-ce-cli`) and a C build toolchain (`build-essential`,
  needed to compile the `exqlite` NIF). Python is **not** needed in the substrate image — agent
  workloads run in their own sibling containers (`agent-discovery:dev` / `agent-generated:dev`).
- **Rationale**: Matches the host toolchain exactly so compiled behaviour is identical; the
  docker CLI is required for sibling dispatch; `exqlite` fails to load without a compiler at
  build time. The implement stage verifies the exact tag by building; adjust if a tag is absent.
- **Alternatives**: Install Elixir via asdf in a plain Debian image — rejected (slower, more
  moving parts than the official hexpm image).

## D9 — Test harness in-container detection

- **Decision**: `start_broker_uds!/1` branches on an env flag set only inside the substrate
  container (e.g. `AOS_IN_CONTAINER=1`, exported by the compose service). When set, it creates
  the per-test socket under the shared volume (`/run/aos/test_<uniq>/inf.sock`) and configures
  volume mode for that test; otherwise it keeps today's `System.tmp_dir!()` behaviour.
- **Rationale**: The same helper serves host unit runs (bind mode, tmp socket) and in-VM docker
  runs (volume mode, shared-volume socket reachable by dispatched agent containers) — FR-008,
  Acceptance 2.2 (per-test isolation) — without a second harness.
- **Alternatives**: A separate in-container helper — rejected (duplication; drift risk).
