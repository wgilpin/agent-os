# Analysis: containerize the substrate so the inference UDS works on macOS

**Status:** working note for a follow-up plan · **Date:** 2026-07-11 · **Target platform: macOS only (OrbStack)**
**Relationship:** follow-on to spec 044 (generated agents sandboxed — DONE). Distinct from roadmap 11-04 (per-agent hardware VM + vsock). This is plain container-to-container UDS.

## Problem

A sandboxed agent (config *or* generated) reaches the inference broker over a Unix domain socket
that `run_worker` bind-mounts into the container at `/tmp/inference.sock`. On this machine that
connection fails with `ECONNREFUSED (111)`, so no sandboxed agent can actually reach the model.

## Root cause (empirically proven)

A Unix socket is **kernel-local**. Today the BEAM broker listens on the **macOS host** kernel
(the app runs via `mix`), while agent containers run in **OrbStack's Linux VM** kernel. A
bind-mount shares the socket's *file node* across the boundary but not the *listening endpoint*,
so `connect()` from the container is refused. This is runtime-independent (Docker Desktop or
OrbStack) — not a virtiofs quirk.

Two probes confirm it:
- macOS-host listener + agent container over `-v host.sock:/c.sock` → `ECONNREFUSED`.
- **Broker container + agent container in the same OrbStack VM, socket on a shared volume →
  `CONNECTED`.** (non-root agent, uid 1000)

**Conclusion:** the path works on macOS **iff the BEAM runs in a container in the same Linux VM
as the agents**, with the socket on a shared volume. No vsock needed (that's the 11-04 endgame
for per-agent *hardware* VMs).

## Why it matters

macOS is the only target. Without this, 044's sandboxing produces agents that are correctly
jailed but **cannot reach the model** — the sandbox↔broker path has never actually run
end-to-end on macOS, only the config agent's non-broker container behaviour has. It also means
the docker-tagged inference E2E tests (e.g. `test/agent_os/isolation_test.exs:83` "hostile web
input") can't pass while the test BEAM runs on the host.

## Solution direction

Run the substrate (BEAM) as a container in the OrbStack VM; put the inference socket on a
**shared volume** mounted into both the substrate container and each agent container.

## Concrete touch points

- **New:** a whole-app Dockerfile + compose (currently none) to run the BEAM in-VM. The
  substrate container creates the broker socket in a shared volume (e.g. `aos_inf:/run/aos`).
- `lib/agent_os/run_worker.ex` → `dispatch_spec/3`: the inference-socket mount source becomes
  the **shared volume**, not `Path.expand(inference_uds_path)` (a host path).
- `lib/agent_os/sandbox.ex` `build_argv/1`: it currently *validates* that the socket mount host
  path equals the configured `inference_uds_path`. That check must be reworked for the
  volume-mount model (it assumes a host bind path today).
- `lib/agent_os/inference_broker.ex`: socket bind path + the socket-dir/GID ownership so a
  non-root agent (uid 1000, aligned to the configured inference GID) can `connect()`
  cross-container. The current `get_configured_gid()` / socket-chgrp path already exists but
  was seen failing (`chgrp … GID 99999: :eperm`) on the host — revisit under the volume model.
- **Test harness:** the docker E2E inference tests need the broker running in-VM (a sidecar /
  compose service), since ExUnit runs the BEAM on the host today. `start_broker_uds!/1` assumes
  an in-process host broker.

## Open design decisions

1. Volume vs. a dedicated bind dir for the socket (volume is same-kernel-clean; bind dirs from
   macOS reintroduce the cross-kernel problem — avoid).
2. Socket directory ownership/permissions across containers (the broker chmods the parent dir
   0700 today; cross-container access needs a shared GID or 0770 group).
3. How dev (`mix`) is run: fully in-container, or a compose target for the docker-inclusive test
   suite only.
4. Whether `sandbox.ex`'s "inference UDS is the sole writable host mount" invariant is restated
   as "the shared inference volume is the sole writable mount."

## Not in scope

- vsock / Apple Containers per-agent hardware VMs (roadmap 11-04).
- Any change to 044's dispatch logic beyond the socket mount **source** (044 is complete and
  correct; generated agents inherit whatever topology the config agent uses — FR-007 parity).

## Verification

Two containers in the VM sharing a socket volume already connect (proven). Success = the
existing docker-tagged inference E2E (`isolation_test` hostile-web + a generated-agent broker
E2E) pass with the substrate containerized, and a real generated agent completes a run reaching
the model from inside its sandbox (spec 044 SC-003, now verifiable on macOS).
