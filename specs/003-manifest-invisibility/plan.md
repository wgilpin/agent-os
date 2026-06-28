# Implementation Plan: Manifest Invisible to the Agent

**Branch**: `003-manifest-invisibility` | **Date**: 2026-06-28 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/003-manifest-invisibility/spec.md`

## Summary

Prove and protect an invariant the architecture already satisfies: the enforcement
**envelope** (the manifest's grants, recipients, methods, spend caps, approval requirements,
and credential references) never reaches any surface the agent can observe. The substrate sends
the agent only `{state, items}` plus the published action schema; it mounts no host paths into
the container; it passes no mutating credential in the agent's environment. This feature adds
**no runtime behavior** — it adds a boundary-invariant contract test that drives the real
payload-construction and sandbox-argv code paths and asserts the envelope is absent from the
payload, the mount set, and the environment, plus an explicit gate-only invariant note in the
run-construction and manifest-owning modules so the guarantee is discoverable and regression
fails loudly.

This was tracked as User Story 2 within 002-manifest-enforcement; it is carved into its own
spec so the invariant is verified by a dedicated contract test rather than assumed by
construction.

## Technical Context

**Language/Version**: Elixir ~> 1.20 (control plane). No Python change.
**Primary Dependencies**: existing only — Jason (boundary JSON encode), YamlElixir (manifest
parse). No new deps.
**Storage**: N/A — no new state. Reads the existing `roster_trust` snapshot and the existing
manifest only as inputs to the invariant test.
**Testing**: ExUnit. One new contract/invariant test (`test/agent_os/boundary_test.exs`). Pure
and deterministic — no Docker required to run it, no live LLM, no live external service
(Constitution IV).
**Target Platform**: Linux/macOS host (unchanged).
**Project Type**: Single project — BEAM control plane + Python agent workload across a port
boundary (unchanged).
**Performance Goals**: N/A — a static invariant check, no runtime hot path touched.
**Constraints**: The test must exercise the real code paths (`RunWorker` payload construction
and `Sandbox.build_argv/1`), not reconstruct them, so it stays honest as the implementation
evolves. The invariant assertions must be about concrete envelope keys and the specific
configured envelope values, not arbitrary substrings.
**Scale/Scope**: One agent, one manifest, one container per invocation (unchanged). One test
module + two `@moduledoc` notes. No production code path changes.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Simplicity First | PASS | Adds one test module and two documentation notes. No new modules, deps, or runtime behavior — the simplest possible way to lock an existing invariant. |
| II. Explicit Scope Control | PASS | Exactly US2 from the 002 roadmap (boundary invariant), nothing more. No payload, mount, or env changes; the test only asserts what already holds. |
| III. Test-Driven Backend | PASS | The deliverable IS a test; written before (re)confirming the invariant in code. If the test ever fails, the production change that broke it is the defect. |
| IV. No Live Dependencies in Tests | PASS | The invariant test constructs the payload and argv in-process; no Docker, no LLM, no remote call. |
| V. Strong Typing, No Bare Maps | PASS | No new entities. The test reads the typed `Manifest` struct and the typed `Sandbox` struct already in place. |
| VI. Loud Failures | PASS | The whole point: a regression that leaks the envelope makes the test fail loudly and blocks merge. |
| VII. Self-Documenting Comments | PASS | Adds explicit `@moduledoc` invariant notes to `run_worker.ex` and `manifest.ex` (FR-007). |
| VIII. Legibility | PASS | Strengthens legibility of the trust boundary: the guarantee is now stated in code and enforced by a test, readable without running the agent. |
| IX. Substrate Owns State & Lifecycle (agent-agnostic) | PASS | No state added. The test asserts envelope absence using concrete configured values, not hard-coded agent vocabulary in `lib/`. |
| X. No Ambient Authority | PASS | This feature directly defends the Principle X invariant that the manifest is privileged-read for the gate only and not readable by the agent. |
| XI. The Gate Is the Only Firewall | PASS | Confirms no mutating credential reaches the agent surface — a precondition for the gate being the sole firewall. |
| XII. Enforcement Precedes Generation | PASS | Pure enforcement hardening on hand-authored manifests; no generation. |

**No violations.** No Complexity Tracking entries required.

## Project Structure

### Documentation (this feature)

```text
specs/003-manifest-invisibility/
├── plan.md                  # This file
├── research.md              # Phase 0 — verify-don't-rebuild decisions
├── data-model.md            # Phase 1 — the envelope, the agent-bound payload, the container surfaces
├── quickstart.md            # Phase 1 — run the invariant test; how to confirm a deliberate leak fails it
├── contracts/
│   └── boundary.md          # The port-boundary invariant: envelope never crosses (payload/mounts/env)
├── checklists/
│   └── requirements.md      # Spec quality checklist (from /speckit-specify)
└── tasks.md                 # Phase 2 — created by /speckit-tasks, NOT here
```

### Source Code (repository root)

```text
lib/agent_os/
├── run_worker.ex            # MODIFIED (docs only) — @moduledoc invariant note: manifest is gate-only, never crosses the boundary
└── manifest.ex              # MODIFIED (docs only) — @moduledoc invariant note: manifest is privileged-read, never sent to the agent

test/agent_os/
└── boundary_test.exs        # NEW — drives RunWorker payload construction + Sandbox.build_argv/1; asserts envelope absent from payload, mount set, env
```

**Structure Decision**: Single project, no new modules. The invariant lives at two existing
seams: the payload `RunWorker` serializes across the port (`{state, items}`) and the argv
`Sandbox.build_argv/1` produces for `docker run`. The contract test reaches into both real code
paths so the assertion tracks the implementation rather than a copy of it. Production behavior is
unchanged; the only `lib/` edits are `@moduledoc` notes.

## Phase 0 — Research

See [research.md](./research.md). Resolves: (1) verify-don't-rebuild — assert against the real
`RunWorker` payload and `Sandbox.build_argv/1` output rather than a reconstructed map, and how to
do that without a Docker run; (2) what exactly constitutes the "envelope" to assert absent
(concrete keys + the specific configured values from the manifest, plus the credential id) and
how to avoid brittle arbitrary-substring checks; (3) where the gate-only invariant note belongs
so it is discoverable at the two owning modules.

## Phase 1 — Design & Contracts

- [data-model.md](./data-model.md) — the **Enforcement envelope**, the **Agent-bound payload**,
  and the **Container surface** (payload / mounts / environment), with the validation rules that
  map to FR-001…FR-007.
- [contracts/boundary.md](./contracts/boundary.md) — the asserted invariant: the substrate→agent
  payload is exactly `{state, items}` (+ action schema); none of the envelope keys/values, the
  manifest path, or any mutating credential appear in the payload, the mount set, or the env.
- [quickstart.md](./quickstart.md) — run the invariant test green; deliberately leak an envelope
  field and watch it fail; the gate-only invariant notes to read.

**Post-design Constitution re-check**: still PASS — no state, no new runtime authority, no agent
vocabulary in `lib/`; the change only documents and tests an existing trust-boundary invariant.
