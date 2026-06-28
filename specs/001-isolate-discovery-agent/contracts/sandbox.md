# Contract: Sandbox Invocation (`docker run` flags)

The exact containment contract the `Sandbox` module renders. These flags ARE the agent's
granted capabilities (Constitution IX — no ambient authority). The `Sandbox` argv builder
is a pure function and is unit-tested against this contract.

## Required flags

```text
docker run
  --rm                         # no leftover container (D2)
  -i                           # attach stdin (boundary input)
  --cidfile <path>             # wrapper records id for trap-cleanup (D2)
  --network none               # no network at all (FR-001/008)
  --read-only                  # root filesystem read-only (FR-001)
  --tmpfs /scratch:rw,size=64m # the single writable location
  --memory <N>m                # memory cap → OOM exits 137 (FR-004)
  --memory-swap <N>m           # equal to --memory: disable swap
  --cpus <C>                   # cpu cap
  --user <nonroot>             # never run as root in-container
  --cap-drop ALL               # drop all Linux capabilities
  --security-opt no-new-privileges
  agent-discovery:<tag>
```

## Egress (FR-008)

- **No egress this phase.** `--network none` means the agent has no network interface at
  all — it cannot reach any host. The agent's reasoning is a deterministic stub with no
  outbound calls (A1 decision), so no allowlist is needed.
- Net effect: a compromised agent cannot exfiltrate anywhere.
- **Deferred**: when a real LLM call is wired, this becomes a single-destination egress
  allowlist (model endpoint only, via a destination-only forward proxy — NOT the v2
  credential proxy).

## Isolation assertions (tested in `isolation_test.exs`, tag `:docker`, stub agent)

1. A stub that tries to read a host path outside `/scratch` fails (read-only FS).
2. A stub that tries any outbound network connection fails (no interface; `--network none`).
3. A stub that writes only to `/scratch` succeeds.
4. A stub that allocates beyond `--memory` is OOM-killed → exit `137` surfaced.
5. A stub that `exit 1` (crash) surfaces non-zero → `:failed` + restart-once-and-alert.
6. On port timeout, the wrapper trap stops the container (no orphan; `docker ps` clean).
