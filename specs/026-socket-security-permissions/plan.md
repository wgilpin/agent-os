# Socket Security & Permissions Hardening

This plan secures the Unix-domain socket used for communication between the substrate
and sandboxed agents. It enforces OS-level DAC (permissions & ownership) on the host
socket and its parent directory, aligns the container's GID with the socket group so the
agent can connect on native Linux, and locks the mount surface so no host state beyond
the socket is exposed.

## User Review Required

> [!IMPORTANT]
> **Primary target is macOS/Docker Desktop**, where the container↔host boundary is a
> hypervisor VM and bind-mount DAC bits are only *softly* enforced across that boundary.
> Therefore the request-level `RUN_TOKEN` remains the **primary, load-bearing auth
> mechanism**; socket permissions and GID alignment are **defense-in-depth**, and — on
> native Linux — the mechanism that actually lets the container connect at all.
>
> **What the permission model buys, precisely:** the socket is already `0755` today, so
> only the owner can `connect()` (the write bit is owner-only). Moving to `0660` + a
> dedicated group does two things: (a) it scopes access to owner + one group and removes
> "other" entirely, and (b) it grants the container's GID group-write so the agent can
> connect **on native Linux**, where — unlike macOS — there is no file-sharing layer to
> bridge a GID mismatch.
>
> **Loud-failure behavior:** if a dedicated GID is explicitly configured but cannot be
> applied (the substrate process runs as a user who is not a member of that group), the
> `InferenceBroker` **crashes loudly and refuses to serve** (`{:stop, ...}` from
> `init/1`) rather than degrading to an unsecured socket.
>
> **Dev-convenience default & its Linux caveat:** if no `INFERENCE_GID` is configured,
> the GID dynamically defaults to the running user's **primary GID** (guaranteeing the
> ownership change always succeeds locally). This is safe on macOS but **weakens the
> control on native Linux**, because the primary group (`staff`, `users`, etc.) may admit
> unrelated host processes. The broker therefore **emits a `Logger.warning` whenever it
> falls back to the primary GID**, and this plan documents that **a native-Linux
> deployment MUST set a dedicated `INFERENCE_GID`.**

## Open Questions

None affecting design. The dedicated-GID *value* is a deployment/provisioning detail,
not a design fork: it defaults dynamically for local dev and is set via `INFERENCE_GID`
in production.

## Security Properties (what this plan must make true)

1. **Host-side scoping:** the socket is owner + dedicated-group only (`0660`); "other"
   host processes cannot connect. The parent `data/` directory is `0700` so the socket
   is not reachable by traversal and no other host state in `data/` is exposed.
2. **Container access on Linux:** the sandboxed agent, launched with the aligned GID,
   can connect through group-write on native Linux (not only via macOS file-sharing).
3. **No unsecured-socket window:** the parent directory is locked to `0700` *before* the
   socket is created, so there is no interval in which the socket sits under a
   world-traversable directory.
4. **Loud failure:** if permissions/ownership cannot be applied, the broker refuses to
   serve rather than falling back to an open socket.
5. **Minimal mount surface:** the container sees only the socket *file*, never the
   `data/` directory — locked by a boundary test so a future change can't silently mount
   the whole directory (which now holds `run_log.md`, `roster.term`, `conformance.term`,
   and `elicitation/`).

## Proposed Changes

### Elixir Kernel / Substrate

#### [MODIFY] `lib/agent_os/inference_broker.ex`

- Add `get_configured_gid/0` resolving the target GID in order:
  1. `System.get_env("INFERENCE_GID")`
  2. Application config `:inference_gid`
  3. **Dynamic fallback** to the current user's primary GID via
     `System.cmd("id", ["-g"])` — trim trailing newline before `String.to_integer/1`.
     When this fallback path is taken, emit `Logger.warning/1` noting that no dedicated
     GID is configured and that native-Linux deployments must set `INFERENCE_GID`.
- Modify `start_uds_listener/1` so the operations occur in this **exact order** to
  guarantee no unsecured-socket window:
  1. `File.rm(socket_path)` (existing) — clear any stale socket.
  2. `Path.dirname(socket_path) |> File.mkdir_p!()` (existing).
  3. **`File.chmod(dir, 0o700)` on the parent directory — BEFORE the listen call.**
  4. `:gen_tcp.listen(...)` (existing) — creates the socket.
  5. `File.chmod(socket_path, 0o660)`.
  6. `:file.change_group(socket_path, gid)` (from `get_configured_gid/0`).
  - Any failure in steps 3, 5, or 6 must `Logger.error/1` loudly with the reason and
    return `{:error, reason}` (match the existing loud-failure style used for the listen
    error path).
- Modify `init/1`: replace the current silently-degrading branch
  (`{:error, _reason} -> {:ok, %{tokens: %{}}}`) with
  `{:error, reason} -> {:stop, {:uds_listener_failed, reason}}` so the broker refuses to
  serve when the socket cannot be secured. (The `autostart: false` branch is unchanged,
  so tests that don't start the listener are unaffected.)

#### [MODIFY] `lib/agent_os/run_worker.ex`

- Resolve the target GID via `AgentOS.InferenceBroker.get_configured_gid/0`.
- Align the container credential: parse the **uid** out of the existing `:user` option
  (which may be `"1000:1000"` or `"1000"`; default uid `1000`) and pass
  `"<uid>:<inference_gid>"` to the `%AgentOS.Sandbox{}` runner — never append a third
  segment (avoid `"1000:1000:<gid>"`). Root-uid refusal from 07-01 remains in force.

### Tests

#### [MODIFY] `test/agent_os/inference_broker_test.exs`

- Verify parent `data/` directory is `0700` and the socket file is `0660`.
- Verify the socket's group ownership matches the configured GID.
- Verify GID resolution order: `INFERENCE_GID` env → `:inference_gid` config → dynamic
  `id -g` fallback (and that the fallback emits the warning).
- Verify `init/1` returns `{:stop, {:uds_listener_failed, _}}` when a permission/group
  adjustment fails (e.g. an explicitly configured GID the user is not a member of).
- **Ordering guarantee:** verify the parent directory is secured before the socket is
  created (no window in which the socket exists under a non-`0700` directory).

> **Known coverage limit (document, do not hand-wave):** these tests assert the
> permission/ownership bits are *set*; they do not prove the security *property* — that
> an out-of-group host process is actually denied `connect()` and that an in-group
> container is actually admitted. That property requires a second GID / a real container
> and is only hard-enforced on Linux. It is covered as far as practical by the
> docker-gated live test below and otherwise noted as a known limit.

#### [MODIFY] `test/agent_os/sandbox_test.exs`

- Verify the Sandbox argv builder emits the aligned credential `--user 1000:<inference_gid>`.
- **Boundary guard (spec req 5):** assert the sandbox mounts only the socket *file*
  (`/tmp/inference.sock`) and never the `data/` directory, so no host state beyond the
  socket can leak through the VM boundary.

## Verification Plan

### Automated Tests

- `mix test test/agent_os/inference_broker_test.exs`
- `mix test test/agent_os/sandbox_test.exs`
- Docker-gated (Linux CI is where mount DAC is hard-enforced and this is most
  meaningful): `mix test --only docker_gated test/agent_os/sandbox_test.exs`

### Manual / Live (macOS)

- Start the substrate; confirm `data/inference.sock` is `srw-rw----` (`0660`) with the
  expected group, and `data/` is `drwx------` (`0700`).
- Run one agent end-to-end and confirm the inference round-trip still completes
  (macOS file-sharing path).
- Confirm that setting `INFERENCE_GID` to a group the running user is **not** a member of
  causes the broker to refuse to start with `{:uds_listener_failed, _}`.

## Scope Boundaries

- **In scope:** socket group ownership + `0660` mode + dedicated-GID resolution +
  container GID alignment; parent-directory `0700`; ordered (no-window) socket lifecycle
  with loud refuse-to-serve; `RUN_TOKEN` reaffirmed as the auth authority; mount-surface
  minimization guard.
- **Out of scope:** read-only FS / `--cap-drop` / resource limits (delivered in 07-01,
  spec 025); network egress policy (`--network none`, already set); the `RUN_TOKEN`
  protocol itself; `SO_PEERCRED` peer-credential checking (Erlang `:gen_tcp` does not
  expose it cleanly — future work).
