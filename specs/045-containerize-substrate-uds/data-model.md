# Phase 1 Data Model: Socket Topology

This feature has no persistent-storage schema change. Its "entities" are configuration state
and the container-runtime topology. They are captured here for the plan's completeness.

## Configuration keys (`config/config.exs`, `:agent_os`)

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `:inference_socket_volume` | `String.t() \| nil` | `nil` | Named Docker volume for the inference socket. `nil` ⇒ **host-bind mode** (current behaviour). Non-nil ⇒ **shared-volume mode**. |
| `:inference_socket_volume_path` | `String.t()` | `"/run/aos"` | Directory where the volume is mounted inside every container. The socket lives under it. Only consulted in shared-volume mode. |
| `:inference_uds_path` | `String.t()` | `"data/inference.sock"` (host-bind) | The socket path. In shared-volume mode this is an in-volume path, e.g. `/run/aos/inference.sock`, identical on both sides. |
| `:inference_gid` (or `INFERENCE_GID` env) | `integer()` | existing | Group that owns the socket (and, in volume mode, its parent dir). Agents run `1000:<gid>`. |

**Invariant**: `:inference_socket_volume == nil` ⇒ every observable behaviour is identical to
pre-feature (SC-004). The mode is a pure function of this one key.

## Socket Topology Mode (derived state)

```
mode =
  if inference_socket_volume == nil, do: :host_bind, else: :shared_volume
```

| Aspect | `:host_bind` (today) | `:shared_volume` (new) |
|--------|----------------------|------------------------|
| Agent inference mount | `{Path.expand(uds_path), "/tmp/inference.sock"}` | `{volume_name, volume_path}` e.g. `{"aos_inf", "/run/aos"}` |
| `INFERENCE_SOCKET` env in agent | `/tmp/inference.sock` | full `:inference_uds_path` (under `volume_path`) |
| Broker socket parent-dir mode | `0700`, no dir chgrp | `0770` + `chgrp` to `INFERENCE_GID` |
| Broker socket mode | `0660` + chgrp (unchanged) | `0660` + chgrp (unchanged) |
| Sandbox writable-mount rule | mount host path == configured `uds_path`; all others `:ro` | writable mount target == `volume_path` and source == `volume_name`; all others `:ro` |

## Substrate Container (runtime entity)

| Property | Value |
|----------|-------|
| Base image | `hexpm/elixir` @ Elixir 1.20.2 / OTP 29 (Debian) + `docker-ce-cli` + `build-essential` |
| Runs BEAM as | root (so it can `chgrp`/`chmod` the volume dir and reach docker.sock) |
| Mounts | `aos_inf:/run/aos` (rw), `/var/run/docker.sock` (sibling dispatch), repo at identical host path `/Users/will/projects/agent_os` (rw), `MIX_DEPS_PATH`/`MIX_BUILD_PATH` → container-local |
| Env | `INFERENCE_GID`, `AOS_IN_CONTAINER=1`, model-key passthrough, `MIX_ENV`, `MIX_DEPS_PATH`, `MIX_BUILD_PATH` |
| Dispatches | **sibling** agent containers via the VM daemon (not nested) |

## Shared Inference Volume (runtime entity)

- Named `aos_inf`, declared in `docker-compose.yml`.
- Holds only the inference socket(s): `/run/aos/inference.sock` for real runs;
  `/run/aos/test_<uniq>/inf.sock` per test under the harness.
- It is the **sole writable mount** presented to agent containers in shared-volume mode; all
  other agent mounts (generated code) remain `:ro`.
