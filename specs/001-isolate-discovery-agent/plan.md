# Implementation Plan: Isolate the Discovery Agent

**Branch**: `001-isolate-discovery-agent` | **Date**: 2026-06-28 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/001-isolate-discovery-agent/spec.md`

## Summary

Move the hand-written Python discovery agent off the host process and into a sandboxed
container, invoked across the **existing** port boundary. The Elixir substrate keeps
ownership of the lifecycle: it builds the sanitized input, launches the container, and
maps the container's exit (including OOM) to a clean BEAM process exit so Phase 1's
restart-once-and-alert keeps working. Untrusted bookmark content is validated and bounded
substrate-side before it crosses the boundary; the container runs with **no network
access**, a read-only filesystem except a scratch dir, and CPU/memory caps. The agent's
reasoning stays a deterministic stub this phase, so no LLM call, credential, or egress is
introduced. No manifest gate, credential proxy, or spend metering is built here (Phase 3).

## Technical Context

**Language/Version**: Elixir ~> 1.20 (control plane) · Python 3.11 (agent workload, `uv`)
**Primary Dependencies**: Erlang Ports (existing `PortRunner`), Docker (container runtime), Pydantic (Python input contract); no new Elixir deps required (extend the existing `priv/port_wrapper.sh` rather than add `muontrap`/`erlexec`)
**Storage**: term-file + git-backed markdown run-log (Phase 1, reused). No external DB.
**Testing**: ExUnit (Elixir) · pytest (Python) · deterministic stub agent for boundary/isolation tests (no live LLM, per Constitution IV)
**Target Platform**: Linux/macOS host with Docker available
**Project Type**: Single project — BEAM control plane + Python agent workload across a port boundary
**Performance Goals**: Not latency-sensitive (one daily run + ad-hoc manual run); container cold-start under a few seconds is acceptable
**Constraints**: Container has no network egress (network disabled); read-only FS + scratch dir; explicit CPU/memory caps; no orphaned containers after a crash/timeout
**Scale/Scope**: One discovery agent, one container per invocation; concurrent multi-agent isolation out of scope

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Simplicity First | PASS | Reuses the port boundary + wrapper; bookmarks loaded from a local export fixture (no live X API yet); cleanup via the existing wrapper (cidfile + trap), not a new dep. No proxy or network setup — the stub agent needs no network, so the container runs `--network none`. No tracked complexity. |
| II. Explicit Scope Control | PASS | Isolation only. No LLM call is wired this phase (agent stays a stub), so no credential and no egress are introduced; the v2 credential proxy is explicitly NOT built here. |
| III. Test-Driven Backend | PASS | Sanitizer + docker-arg builder are pure functions, written test-first. |
| IV. No Live Dependencies in Tests | PASS | Isolation/exit/OOM tests run the deterministic stub agent in-container; no LLM call in any test. |
| V. Strong Typing, No Bare Maps | PASS | Python input via a Pydantic model; Elixir sandbox config + sanitized item as structs/typespecs, not bare maps. |
| VI. Loud Failures | PASS | Log container start, exit code, OOM cause, and every sanitizer rejection. No silent excepts. |
| VII. Self-Documenting Comments | PASS | Every new function gets a purpose doc; the wrapper and Dockerfile get intent comments. |
| VIII. Substrate Owns State & Lifecycle | PASS | Substrate owns container start/stop/cleanup; the agent stays an invocation-scoped pure function — the container IS the one-shot invocation. |
| IX. No Ambient Authority | PASS | The container receives only its granted input (sanitized bookmarks) and one granted egress (LLM endpoint). No host FS, env, or substrate state. |
| X. Gate Is the Only Firewall | PASS | No LLM key in the container this phase (the agent is a stub); the privileged **write** still goes through the substrate effector (Phase 1), never the agent. When a real model is wired later, its key is inference-only (non-mutating). |
| XI. Enforcement Precedes Generation | N/A | This is the isolation phase, prior to enforcement. No generation introduced. |

**No unjustified violations, and no tracked complexity** (see Complexity Tracking below).

## Project Structure

### Documentation (this feature)

```text
specs/001-isolate-discovery-agent/
├── plan.md              # This file
├── research.md          # Phase 0 — isolation/runtime decisions
├── data-model.md        # Phase 1 — entities & validation rules
├── quickstart.md        # Phase 1 — build image, run, test
├── contracts/
│   ├── boundary.md      # Port-boundary JSON contract (substrate ↔ container)
│   └── sandbox.md       # Container invocation contract (docker run flags)
└── tasks.md             # Phase 2 — created by /speckit-tasks, NOT here
```

### Source Code (repository root)

```text
lib/agent_os/
├── sandbox.ex           # NEW — builds the `docker run` argv + resource/egress flags
├── sanitizer.ex         # NEW — validates + bounds + normalizes untrusted bookmark items
├── port_runner.ex       # MODIFIED — invoke `docker run` (via the wrapper) instead of `python`
├── run_worker.ex        # MODIFIED — pass sanitized input; treat non-zero/137 exit as clean failure
├── provisioner.ex       # MODIFIED — load bookmark export fixture as the agent's input source
└── ...                  # (effector, run_log, inventory, scheduler, run_supervisor reused as-is)

priv/
└── port_wrapper.sh      # MODIFIED — write cidfile, trap EXIT → `docker stop`/`kill` (no orphans)

agents/discovery/
├── Dockerfile           # NEW — python:3.11-slim + uv + agent code (non-root)
├── models.py            # NEW — Pydantic model for the input contract
├── main.py              # MODIFIED — validate input via models.py before reasoning
└── test_main.py         # MODIFIED — contract/sanitization tests (no LLM)

test/agent_os/
├── sandbox_test.exs     # NEW — docker argv builder (pure)
├── sanitizer_test.exs   # NEW — sanitization rules (pure)
└── isolation_test.exs   # NEW — tagged :docker — runs stub agent in-container, asserts clean exit/OOM
```

**Structure Decision**: Single project, extending the Phase 1 layout. The port boundary is
the integration seam — containerization swaps what the wrapper spawns (`docker run …`
instead of `python …`), so `PortRunner`'s exit-status surfacing and the
`RunWorker`/`RunSupervisor` restart-once-and-alert path are reused unchanged in shape.

## Complexity Tracking

No constitution violations and no tracked complexity. The egress-proxy sidecar considered
earlier was removed by the A1 scope decision: with the agent reasoning as a deterministic
stub, the container runs `--network none` (deny-all) — both simpler and a stronger
isolation guarantee than an allowlist-via-proxy. The LLM egress allowlist is deferred to
the phase that wires a real model.

## Phase 0 — Research

See [research.md](./research.md). Resolves: container runtime & invocation across the port
boundary; orphan-free cleanup on crash/timeout; OOM/crash → clean exit mapping; network
isolation (deny-all); untrusted-input sanitization strategy & ingestion source; test
strategy without a live LLM.

## Phase 1 — Design & Contracts

- [data-model.md](./data-model.md) — Sanitized Bookmark Item, Sandbox Run Config, Run
  Record (extended), with validation rules from FR-001…FR-010.
- [contracts/boundary.md](./contracts/boundary.md) — the JSON the substrate feeds in and
  the action list it expects back, unchanged in shape from Phase 1 but now schema-validated
  on both sides.
- [contracts/sandbox.md](./contracts/sandbox.md) — the container invocation contract: the
  exact `docker run` flag set that enforces FR-001/FR-008 and the exit-code semantics for
  FR-004/FR-005.
- [quickstart.md](./quickstart.md) — build the image, do a manual on-demand run, run the
  test suites.

**Post-design Constitution re-check**: still PASS — the design adds no mutating credential
to the agent, keeps the substrate as the sole state/lifecycle owner, and stays within the
isolation scope.
