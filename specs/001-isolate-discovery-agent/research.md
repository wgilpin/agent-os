# Phase 0 Research: Isolate the Discovery Agent

All decisions resolve the Technical Context unknowns for the isolation phase. Each is the
leanest option that satisfies the requirement (Constitution I).

## D1 — Container runtime & invocation across the port boundary

- **Decision**: Use **Docker**. The substrate launches `docker run --rm -i …
  agent-discovery:<tag>` *through the existing `priv/port_wrapper.sh`*; the wrapper feeds
  the input JSON on stdin (forwarded to the container's stdin) and the container's stdout
  carries the action list back. `PortRunner.run/4` is called with `cmd = "docker"` and the
  argv built by the new `Sandbox` module.
- **Rationale**: The port boundary already surfaces child exit status (`PortRunner` returns
  `{:error, {:exit_status, code}}`). Swapping the spawned command from `python …` to
  `docker run …` reuses that machinery unchanged — minimal new surface.
- **Alternatives considered**: `:erlexec` / `muontrap` as the process manager (more
  control, but a new dependency and a second way to spawn — rejected for Phase 1 reuse);
  Podman (rootless is attractive but Docker is the assumed local runtime — revisit later).

## D2 — Orphan-free cleanup on crash/timeout

- **Decision**: Extend `priv/port_wrapper.sh` to (a) pass `--cidfile` to `docker run`, and
  (b) `trap` EXIT to `docker stop` (then `docker kill` after a short grace) the recorded
  container id. `docker run --rm` removes the stopped container.
- **Rationale**: When the BEAM `Port.close` fires (timeout) or the wrapper dies, attached
  `docker run` does not reliably stop the container; the cidfile + trap guarantees no
  orphaned container or leaked egress. Keeps cleanup at the wrapper layer that already
  owns "kill the child when stdin closes" — no new Elixir dependency.
- **Alternatives considered**: `muontrap` (kills the OS process group, but the *container*
  can still outlive the docker client — does not solve the orphan-container case); relying
  on `--rm` alone (does not stop a still-running container).

## D3 — OOM / crash → clean BEAM exit

- **Decision**: Set `--memory` (and `--memory-swap` equal, to disable swap) and `--cpus`.
  An OOM kill exits the container `137`; a crash exits non-zero. `PortRunner` already maps
  any non-zero exit to `{:error, {:exit_status, code}}`. `RunWorker` classifies that as a
  failed run and lets `RunSupervisor` apply restart-once-and-alert.
- **Rationale**: No special OOM handling needed — the container boundary turns a memory
  blow-up into an ordinary non-zero exit, which Phase 1 already treats as a clean failure.
  This is exactly the "let-it-crash across the boundary" goal (FR-004/FR-005).
- **Alternatives considered**: cgroup inspection for an explicit OOM reason (nice-to-have
  for the log; we capture exit `137` as the OOM signal and log it, without extra tooling).

## D4 — Network isolation (FR-008)

- **Decision**: Run the agent container with **`--network none`** (no network at all),
  `--read-only` root filesystem, and a single `--tmpfs /scratch`. No proxy, no custom
  network.
- **Rationale**: The agent's reasoning is a deterministic stub this phase (A1 decision) —
  it makes **no outbound calls**, so it needs no egress whatsoever. Deny-all is both
  simpler and a strictly stronger isolation guarantee than an allowlist-via-proxy, and it
  removes the only piece of added complexity. Bookmarks are ingested substrate-side (D5),
  so nothing inside the container needs the network.
- **Deferred**: when a real LLM call is wired (a later phase), the agent will need exactly
  one egress (the model endpoint, e.g. `gemini-3-flash-preview`). That is when an egress
  **allowlist** (a destination-only forward proxy — NOT the v2 credential proxy) becomes
  warranted. Building it now would guard a call that does not exist.
- **Alternatives considered**: egress-allowlist forward-proxy now (premature — guards a
  non-existent call; rejected on Simplicity); host `iptables` (host-specific; moot under
  deny-all).

## D5 — Untrusted-input sanitization & ingestion source (FR-003, FR-009)

- **Decision**: For v1, the **substrate ingests** bookmarks from a local export file
  (the operator's exported bookmarks JSON) — no live X API yet. A new `Sanitizer` module
  validates each item against the contract (id/author/text/urls, correct types), enforces
  size bounds, normalizes/strips control characters, and rejects malformed items (logged).
  The sanitized items cross the boundary; the Python side re-validates with a Pydantic
  model as defense-in-depth.
- **Rationale**: Prompt-injection text cannot be fully "sanitized" away — the **real**
  defense is capability isolation (US1): even a fully injected agent cannot act
  out-of-grant. Sanitization here is structural validation + bounding + normalization, a
  defense-in-depth layer. Ingesting from a local export keeps the live X API (auth, a
  second egress) out of v1 (Constitution I); "untrusted" is preserved because the content
  is still hostile-by-assumption web text.
- **Alternatives considered**: live X API fetch in v1 (adds OAuth + a second allowlisted
  egress — deferred); attempting semantic prompt-injection scrubbing (false sense of
  safety; isolation is the actual boundary).

## D6 — Test strategy without a live LLM (Constitution IV)

- **Decision**: Three layers. (1) **Pure unit tests** (TDD) for `Sanitizer` and the
  `Sandbox` argv builder — no Docker, no network. (2) **Tagged `:docker` integration
  tests** that run the deterministic **stub** agent image and assert: clean exit on
  success, non-zero/`137` surfacing on forced crash/OOM, and that an out-of-grant
  filesystem/network access fails. (3) **Python pytest** for the Pydantic input contract
  and sanitization parity. No test calls a real model.
- **Rationale**: Keeps the fast suite hermetic; quarantines Docker-dependent tests behind a
  tag so they only run where Docker is present, matching the constitution's "no remote in
  tests" and TDD-for-backend rules.
- **Alternatives considered**: mocking Docker entirely (would not actually verify
  isolation — the integration layer is where the safety claims are proven).

## Open items deferred (NOT this phase)

- Egress allowlist for the agent's LLM call — built when the real model is wired (A1
  decision: the v1 stub runs `--network none`, so there is nothing to allowlist yet).
- Live X API ingestion + its egress entry (Phase 2.x or later).
- Credential proxy / credential injection (Phase 3, v2).
- Manifest-enforced provisioning of the container's grants (Phase 3 — here the grants are
  hard-wired in the `Sandbox` flags, consistent with Phase 1's hard-wired provisioning).
