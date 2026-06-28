---
description: "Task list for Manifest Invisible to the Agent"
---

# Tasks: Manifest Invisible to the Agent

**Input**: Design documents from `specs/003-manifest-invisibility/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/boundary.md

**Tests**: INCLUDED — the spec's sole deliverable IS a boundary-invariant contract test
(Constitution III test-first backend; FR-006). The test is written red first, then the small
payload-extraction refactor makes it green.

**Organization**: A single P1 user story (US1). No foundational phase is needed — there is no
new shared infrastructure, state, or dependency.

## Path Conventions

Single project, BEAM control plane (`lib/agent_os/`, `test/agent_os/`). Paths are from
plan.md §Project Structure.

---

## Phase 1: Setup (Baseline)

**Purpose**: Confirm a clean starting point so any later failure is attributable to this feature.

- [x] T001 Run `mix test --exclude docker` and confirm the suite is green before any change (baseline for the invariant work)

**Checkpoint**: Suite green; safe to add the invariant test and the payload-extraction refactor.

---

## Phase 2: User Story 1 — Envelope absent from every agent-reachable surface (P1) 🎯 MVP

**Goal**: Prove and protect that the enforcement envelope never reaches the agent-bound payload,
the container mount set, or the agent environment, guarded by an automated contract test and a
discoverable in-code invariant note.

**Independent Test**: Run `mix test test/agent_os/boundary_test.exs` — it drives the real payload
producer and `Sandbox.build_argv/1` and asserts the envelope (keys + configured values +
credential id) is absent from payload, mounts, and env, with an anti-vacuousness guard.

- [x] T002 [US1] Write the boundary-invariant test in `test/agent_os/boundary_test.exs` (TDD red): (a) load the real manifest via `AgentOS.Manifest.load("manifests/discovery.md")` and assert it has non-empty `grants` and a non-nil `spend` (anti-vacuousness, VR-006); (b) build the agent-bound payload via `AgentOS.RunWorker.build_payload/2` (introduced in T003) from a sample roster snapshot + items, serialize with `Jason.encode!/1`, and assert top-level keys are exactly `["items", "state"]` (VR-001), none of the envelope keys `grants/recipients/methods/cost/requires_approval/spend/cap/window/on_breach` appear (VR-002), and none of the configured envelope values read from the loaded manifest nor the `outbound_token` credential id appear (VR-003); (c) call `AgentOS.Sandbox.build_argv/1` on a representative `%Sandbox{}` and assert no `-v`/`--volume` flag and no element referencing `manifest`/`discovery.md` (VR-004) and no `outbound_token` in the env args (VR-005), per `contracts/boundary.md`
- [x] T003 [US1] Extract the `{state, items}` payload construction from the `with` chain in `lib/agent_os/run_worker.ex` into a public, typed, `@doc`'d `build_payload/2` (snapshot, items → map) and have `run_once/1` call it (single source of truth for the boundary payload); make the payload assertions in T002 green without changing what crosses the boundary
- [x] T004 [P] [US1] Add an `@moduledoc` invariant note to `lib/agent_os/run_worker.ex` stating the manifest is gate-only and the agent-bound payload is exactly `{state, items}` + action schema — it never carries envelope data; name `test/agent_os/boundary_test.exs` as the enforcement (FR-007, VR-007)
- [x] T005 [P] [US1] Add an `@moduledoc` invariant note to `lib/agent_os/manifest.ex` stating the manifest is privileged-read for the gate only and never crosses the port boundary into the agent; name `test/agent_os/boundary_test.exs` as the enforcement (FR-007, VR-007)

**Checkpoint**: US1 independently testable — `mix test test/agent_os/boundary_test.exs` is green; the envelope is provably absent from payload, mounts, and env.

---

## Phase 3: Polish & Cross-Cutting Concerns

**Purpose**: Quality gates and end-to-end confirmation.

- [x] T006 [P] Run `mix format` and Credo, and resolve any Dialyzer warning, for the changed modules (`lib/agent_os/run_worker.ex`, `lib/agent_os/manifest.ex`) and the new test (Quality Gates)
- [x] T007 Run the full `mix test --exclude docker` suite and confirm no regression from the `build_payload/2` extraction
- [x] T008 Validate `specs/003-manifest-invisibility/quickstart.md` end-to-end: green path passes, a deliberately injected envelope leak fails the test, then revert

---

## Dependencies

- **T001** (baseline) → before any change.
- **T002** (test, red) → **T003** (extraction makes payload assertions green). T002 is written
  first per TDD; it references `build_payload/2` which T003 introduces.
- **T004** and **T005** are independent doc-only edits to different files — parallelizable [P],
  and independent of T002/T003.
- **T006/T007/T008** (polish) → after T002–T005.

## Parallel Execution

- After T003, run **T004** and **T005** together (different files, doc-only).
- **T006** can start as soon as T002–T005 land.

## Implementation Strategy

US1 is the entire feature and the MVP. Deliver it in order T001 → T002 → T003 → (T004 ‖ T005),
then polish. No runtime behavior changes beyond extracting a payload helper that returns exactly
today's `{state, items}` map.
