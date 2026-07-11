# Quickstart: Containerized Substrate

The substrate runs **only containerized** (spec 045 amendment). A host app start on macOS is
refused loudly by the boot guard (`lib/agent_os/application.ex`) because a host-run BEAM broker's
Unix socket is kernel-local and unreachable from agent containers in the OrbStack VM. The
container does everything: scheduler, triggers, generation, elicitation, and the LiveView web UI.

## Host workflow (tests only — unchanged, default)

```bash
mix test          # hermetic; docker-tagged tests excluded by default. No container needed.
```

Day-to-day host **test** work is unchanged: autostart is disabled in the test env, so the boot
guard never fires and the suite stays hermetic. With no `:inference_socket_volume` configured, the
substrate and sandbox behave exactly as before this feature (host-bind mode).

Note: `iex -S mix` / `mix run --no-halt` on the macOS host is **refused** (autostart is enabled
outside the test env) — that is the point. Run the app via the container below.

## Containerized substrate (macOS + OrbStack)

Prereq: OrbStack running; the agent images built (`agent-discovery:dev`, `agent-generated:dev`).

### Build the substrate image

```bash
docker compose build substrate
```

### Run the full app — the one and only way (SC-006 / FR-012 / FR-013)

```bash
docker compose up substrate
```

Starts the full app in the OrbStack VM (`MIX_ENV=dev`, `mix run --no-halt`): scheduler, triggers,
generation pipeline, elicitation, and the LiveView web UI bound to `0.0.0.0:4000` inside the
container and published to the macOS host. Open **http://localhost:4000** in the host browser;
live (websocket-backed) views work. The inference socket is created on the shared `aos_inf` volume
(mounted at `/run/aos` in the substrate and every dispatched agent container), so the
sandbox↔broker path runs end-to-end. Repo-local `data/*.db` state persists to the working tree via
the bind mount (survives container restarts). Stop with `docker compose down`.

The `substrate` service is configured for shared-volume mode: `:inference_socket_volume = "aos_inf"`,
`:inference_socket_volume_path = "/run/aos"`, `INFERENCE_GID`, `AOS_IN_CONTAINER=1` (activates
shared-volume topology and satisfies the boot guard), a baked Linux Python venv at `/opt/aos/venv`
(`PYTHON_BIN`, used by the discovery/elicitor/judge port workloads), and container-local
`MIX_DEPS_PATH`/`MIX_BUILD_PATH` so container build artifacts never touch the host `_build`.

The model credential is `:model_key`, resolved by `CredentialSource` from the `MODEL_KEY` env var
or from `.env` (bind-mounted with the repo, loaded at startup outside `MIX_ENV=test`). A dev-env
run picks up the key from the repo's `.env` automatically; override with `-e MODEL_KEY=...`.

### Run the docker-tagged test suite in-VM (SC-002)

```bash
docker compose run --rm e2e
```

The `e2e` service shares the same image and volumes as `substrate` but runs `MIX_ENV=test` and the
default command `mix deps.get && mix test --only docker`. `--only docker` runs exactly the
sibling-container E2E tests that require the containerized substrate — the hostile-web isolation
E2E and the generated-agent broker E2E — both of which pass. The full unit suite is the host's job
(`mix test` on the host, green and hermetic).

To run the broader suite in-VM instead:

```bash
docker compose run --rm e2e mix test --include docker
```

**Volume name pinning**: the compose volume is pinned to the real name `aos_inf` (not the
compose-prefixed `agent_os_aos_inf`) so the substrate's `docker run -v aos_inf:/run/aos` sibling
dispatch mounts the SAME volume that holds the socket. Without pinning the socket is invisible
cross-container.

### Real generated-agent run reaching the model (SC-001)

`docker compose up substrate` in dev already reaches the model when `.env`/`MODEL_KEY` holds a live
key. A real model call needs a live key, so exercising SC-001 end-to-end is an operator step, not
an automated test.

## Mode reference

| `:inference_socket_volume` | Mode | Socket path | Runs where |
|----------------------------|------|-------------|------------|
| `nil` (default) | host-bind | `data/inference.sock` → `/tmp/inference.sock` | host `mix test` only |
| `"aos_inf"` | shared-volume | `/run/aos/inference.sock` (identical both sides) | substrate container |

## Troubleshooting (loud failures — FR-009)

- App refuses to start on the host with "the substrate runs only containerized on macOS" ⇒ working
  as designed (FR-011). Run `docker compose up substrate`.
- `ECONNREFUSED` from an agent ⇒ you are almost certainly in host-bind mode on macOS; run via the
  substrate container instead.
- Broker `init` stops with `{:uds_listener_failed, {:change_group_failed, reason}}` ⇒ check
  `INFERENCE_GID`; inside the container the BEAM runs as root and chgrp should succeed.
- Sibling agent container can't find its code mount ⇒ the repo must be mounted into the substrate
  at the identical absolute host path (`/Users/will/projects/agent_os`).
