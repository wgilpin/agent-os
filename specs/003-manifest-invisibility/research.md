# Phase 0 Research: Manifest Invisible to the Agent

This feature locks an invariant the current architecture already satisfies. "Research" here is
deciding how to assert it honestly and durably, not choosing a technology.

## D1 — Verify, don't rebuild: assert against the real code paths

**Decision**: The invariant test drives the two real code paths that produce agent-reachable
surfaces — the payload `RunWorker` serializes across the port and the argv
`Sandbox.build_argv/1` builds for `docker run` — rather than reconstructing a `{state, items}`
map inline in the test.

**Rationale**: A test that hand-builds the payload only proves the test author knows the
contract; it does not catch a regression where `RunWorker` later starts adding manifest data to
the real payload. Asserting against the real producers makes the test track the implementation.

**How (without a Docker run)**:
- `Sandbox.build_argv/1` is a pure function over a `%Sandbox{}` struct — call it directly and
  inspect the returned argv list. No container needed.
- The payload is built inside `RunWorker.run_once/1`'s `with` chain. The honest options, in
  preference order:
  1. Extract the payload construction into a small pure private→public helper
     (e.g. `RunWorker.build_payload(snapshot, items)`) that `run_once/1` calls, and assert on
     its output. Keeps one source of truth and is directly testable.
  2. If extraction is judged out-of-scope churn, assert at the boundary by capturing the JSON
     `run_worker` sends in the non-docker path via the existing test seam.
- Resolve the exact approach in Phase 1 design / tasks; both keep the assertion against real
  code. Preference is option 1 (a tiny, well-documented helper) because it is the least brittle
  and most legible.

**Alternatives rejected**: Reconstructing the payload in the test (proves nothing about
regressions); a full `:docker` integration test (slower, needs Docker, and the surfaces are
determinable without actually launching a container — Constitution I/IV favor the in-process
check).

## D2 — What "the envelope" means for the assertion

**Decision**: Assert absence of (a) the concrete envelope **keys** and (b) the specific
**values** configured in the live manifest, plus the credential id from the registry — not
arbitrary English substrings.

- Keys: `grants`, `recipients`, `methods`, `cost`, `requires_approval`, `spend`, `cap`,
  `window`, `on_breach`.
- Values: the configured connector/grant names, recipient identifiers, method names, and spend
  figures read from the loaded `Manifest` struct + the credential id (e.g. `outbound_token`)
  from the connector registry.

**Rationale**: Asserting concrete configured values (pulled from the loaded manifest, not
copy-pasted) makes the test meaningful and self-updating, and avoids the brittleness of banning
common words that could legitimately appear in run data (e.g. an item title containing "send").
The edge case in the spec is handled: the invariant is about envelope-derived content, not
arbitrary substrings.

**Anti-vacuousness guard**: The test first loads the real manifest and asserts it genuinely
carries grants and a spend cap, so the subsequent absence assertions cannot pass trivially
against an empty manifest.

**Alternatives rejected**: Banning a fixed English word list (brittle, false positives);
asserting only top-level keys (misses values and credentials).

## D3 — Where the gate-only invariant note belongs

**Decision**: Add an explicit invariant statement to the `@moduledoc` of two modules:
- `lib/agent_os/run_worker.ex` — the module that builds and sends the agent-bound payload.
- `lib/agent_os/manifest.ex` — the module that owns/loads the manifest.

**Rationale**: These are the two places a future contributor would touch when (accidentally)
threatening the invariant — adding a field to the payload, or exposing the manifest. A note at
exactly those seams is the most discoverable guard (FR-007, Principle VII). The note names the
test so a reader can find the enforcement.

**Alternatives rejected**: A standalone doc file (less discoverable at the point of change); a
code comment buried at the call site (easy to miss vs the module's `@moduledoc`).

## Summary

No new technology, dependencies, or runtime behavior. The work is: one in-process contract test
driving the real payload and argv producers, asserting envelope keys/values/credentials are
absent from payload + mounts + env, anchored by an anti-vacuousness check; plus two `@moduledoc`
invariant notes. All NEEDS CLARIFICATION: none.
