---
description: "Task list for Deterministic Capability Render"
---

# Tasks: Deterministic Capability Render

**Input**: Design documents from `/specs/009-capability-render/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/capability_render.md

**Tests**: REQUIRED. Constitution III (Test-Driven Backend) mandates TDD for backend logic;
the contract enumerates 12 tests (C1–C12). All tests run with no live dependencies
(Constitution IV — no network/model/Docker).

**Organization**: Tasks grouped by the three user stories from spec.md (US1 P1 / US2 P2 / US3 P3).
Because the feature is a single pure module, US1 is the MVP that implements the bulk of
`AgentOS.CapabilityRender`; US2 and US3 add guarantees (mostly additional tests against the same
code, plus small implementation branches) and remain independently testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: US1 / US2 / US3 (Setup/Foundational/Polish carry no story label)

## Path Conventions

Single Elixir app. Source under `lib/agent_os/`, tests under `test/agent_os/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Confirm the workspace is ready; no new dependencies are introduced by this feature.

- [ ] T001 Confirm the build is green before changes: run `mix test`, `mix format --check-formatted`, and `mix credo` from repo root and note any pre-existing failures to fix (Constitution: fix all failing tests).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Create the typed shapes and module skeleton every user story tests against.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [ ] T002 Create the `AgentOS.CapabilityRender.Entry` struct in `lib/agent_os/capability_render/entry.ex` with typed fields `connector`, `phrase`, `danger` (`:read_only | :local | :external`), `recipients`, `methods`, `phrase_source` (`:mapped | :fallback`) per data-model.md; `@enforce_keys` on `connector`, `phrase`, `danger`, `phrase_source`. Add a moduledoc purpose comment.
- [ ] T003 Create the module skeleton `AgentOS.CapabilityRender` in `lib/agent_os/capability_render.ex` with a moduledoc, the `@phrases` generic-keyed map placeholder, and stub function heads `entries/1`, `format/1`, `render/1`, and a private `danger_tier/1` that all currently raise `RuntimeError, "not implemented"`. Add `@spec`s matching contracts/capability_render.md. Ensure it compiles (`mix compile`).

**Checkpoint**: Module + Entry struct compile; tests can reference them.

---

## Phase 3: User Story 1 — Non-coder reads every capability and sees which are dangerous (Priority: P1) 🎯 MVP

**Goal**: Render the discovery agent's grants to a total, danger-ranked, normie-readable view and
surface it in the standing inventory.

**Independent Test**: Render the discovery manifest; both `kv_append` and `external_send` appear as
readable phrases, `external_send` is visibly higher-danger than `kv_append`, and the standing
inventory shows the capability view instead of raw grant structs.

### Tests for User Story 1 (write first, must FAIL before implementation) ⚠️

- [ ] T004 [P] [US1] Add C1/C2 totality tests in `test/agent_os/capability_render_test.exs`: `entries/1` returns exactly one entry per grant for the discovery manifest; both `kv_append` and `external_send` present; a manifest holding an `external_send` grant always yields an entry for it (send never dropped).
- [ ] T005 [P] [US1] Add C3/C4 danger-ranking tests in `test/agent_os/capability_render_test.exs`: `external_send` entry is `:external` and `kv_append` is `:local` (`:external` outranks `:local`); danger derives from the registry — overriding `Connector.registry()` (via `Application.put_env(:agent_os, :connector_registry, …)`, restored in `on_exit`) to make a connector free/credential-less/no-approval changes its tier to `:local`, while changing a grant's `recipients`/`methods` does NOT change its tier.
- [ ] T006 [US1] Add C12 surface test in `test/agent_os/inventory_test.exs`: `AgentOS.Inventory.render/1` output contains the readable capability phrases under a `CAPABILITIES:` heading and no longer contains a raw `%AgentOS.Manifest.Grant{` struct dump.
- [ ] T006a [P] [US1] Add C3-format test (FR-005/SC-003) in `test/agent_os/capability_render_test.exs`: assert the **rendered text** distinguishes danger tiers — the formatted line for `external_send` carries a danger marker that the `kv_append` line does not (test the marker's presence/absence, not a specific glyph). This pins the danger-ranked guarantee at the presentation layer, not just the `Entry.danger` field.

### Implementation for User Story 1

- [ ] T007 [US1] Populate the `@phrases` map in `lib/agent_os/capability_render.ex` keyed by generic capability name (`"kv_append"`, `"external_send"`) per data-model.md; comment that keys are generic (agent-agnostic, FR-008).
- [ ] T008 [US1] Implement private `danger_tier/1` in `lib/agent_os/capability_render.ex` using ONLY the registry capability fields (`mutating?` / `requires_approval?` / `credential` / `cost`): `:read_only` if not mutating; `:local` if mutating and no credential, no approval, zero cost; else `:external`. Comment the rule at its definition (FR-004, FR-006).
- [ ] T009 [US1] Implement `entries/1` in `lib/agent_os/capability_render.ex`: read the registry via `AgentOS.Connector.registry()` (same accessor enforcement uses), map each grant (in order) to an `Entry` with phrase (from `@phrases`), `danger` (from `danger_tier/1`), and echoed `recipients`/`methods`; one entry per grant, no merge (FR-001/FR-002).
- [ ] T010 [US1] Implement `format/1` and `render/1` in `lib/agent_os/capability_render.ex`: one line per entry under a `CAPABILITIES:` heading, with `:external` visually/semantically distinct from `:local`/`:read_only` via a per-line danger marker (FR-005, verified by T006a), scope shown when present; deterministic output. `render/1 == format(entries(m))`.
- [ ] T011 [US1] Wire the render into `lib/agent_os/inventory.ex`: replace the `GRANTS: #{inspect(manifest.grants)}` line with `AgentOS.CapabilityRender.render(manifest)` output (a `CAPABILITIES:` block). Keep the rest of the inventory unchanged.
- [ ] T012 [US1] Run `mix test test/agent_os/capability_render_test.exs test/agent_os/inventory_test.exs`, then `mix format` + `mix credo`; confirm T004–T006 pass.

**Checkpoint**: The discovery agent's capability view is total, danger-ranked, readable, and live in the standing inventory — MVP complete.

---

## Phase 4: User Story 2 — The view cannot drift from what is enforced (Priority: P2)

**Goal**: Prove (and where needed, enforce) that add/remove/rescope of grants changes the render
correspondingly, with no separately maintained description.

**Independent Test**: Mutate a manifest's grants three ways and confirm the render tracks each change.

### Tests for User Story 2 (write first, must FAIL or expose gaps before implementation) ⚠️

- [ ] T013 [P] [US2] Add C5/C6 faithfulness tests in `test/agent_os/capability_render_test.exs`: adding a grant adds exactly one corresponding entry; removing a grant removes its entry (one-to-one correspondence with `manifest.grants`).
- [ ] T014 [P] [US2] Add C7 scope-faithfulness test in `test/agent_os/capability_render_test.exs`: changing a grant's `recipients`/`methods` changes that entry's echoed scope (and the formatted line), while leaving its phrase and danger tier unchanged.

### Implementation for User Story 2

- [ ] T015 [US2] If T014 exposes that scope is not echoed in `entries/1`/`format/1`, complete the scope echo in `lib/agent_os/capability_render.ex` so recipients/methods are reflected faithfully (FR-003). Then run `mix test`, `mix format`, `mix credo`.

**Checkpoint**: Faithfulness proven across add/remove/rescope; no drift path remains.

---

## Phase 5: User Story 3 — Mechanical, deterministic, unable to be model-authored (Priority: P3)

**Goal**: Lock in determinism, agent-agnosticism, the totality fallback, and loud failure.

**Independent Test**: Render the same manifest twice for byte-identical output; the same capability
renders identically regardless of agent; an unmapped connector degrades visibly; a registry-missing
connector raises.

### Tests for User Story 3 (write first, must FAIL before implementation) ⚠️

- [ ] T016 [P] [US3] Add C8/C11 tests in `test/agent_os/capability_render_test.exs`: `format(entries(m))` is byte-identical across repeated calls (deterministic, no LLM); the same capability name renders the same phrase + danger tier across two different manifests/agents (agent-agnostic).
- [ ] T017 [P] [US3] Add C9 fallback test in `test/agent_os/capability_render_test.exs`: a grant for a registry-known connector that has NO `@phrases` entry still produces an entry with a deterministic fallback phrase, `phrase_source: :fallback`, correct danger tier — never dropped (uses a registry override to introduce an extra connector).
- [ ] T018 [P] [US3] Add C10 loud-failure test in `test/agent_os/capability_render_test.exs`: a grant whose connector is absent from `Connector.registry()` at render time raises (does not silently drop or guess a danger level). Also assert the empty-grants case renders an explicit "no capabilities granted" line.

### Implementation for User Story 3

- [ ] T019 [US3] In `lib/agent_os/capability_render.ex`, add the fallback branch (unmapped phrase → deterministic fallback string + `phrase_source: :fallback`), the loud-failure branch (connector missing from `Connector.registry()` → raise with a clear message, Constitution VI), and the empty-entries message in `format/1`. Then run `mix test`, `mix format`, `mix credo`.

**Checkpoint**: All four properties (faithful/total/danger-ranked/never-LLM) and edge cases proven.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final validation and traceability.

- [ ] T020 Run the full suite `mix test` plus `mix format --check-formatted` and `mix credo --strict` from repo root; fix any failures (including any pre-existing ones noted in T001).
- [ ] T021 [P] Run the quickstart.md worked example against `manifests/discovery.md` and confirm the rendered output matches the description (kv_append local, external_send egress/higher-danger).
- [ ] T022 [P] Confirm every contract test C1–C12 in contracts/capability_render.md maps to an implemented test (traceability check); note the mapping in a comment block at the top of `test/agent_os/capability_render_test.exs`.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup. BLOCKS all user stories (struct + module must exist to compile tests).
- **User Story 1 (Phase 3)**: Depends on Foundational. The MVP; implements the bulk of the module.
- **User Story 2 (Phase 4)**: Depends on US1 (tests/refines the same `entries/1`/`format/1`).
- **User Story 3 (Phase 5)**: Depends on US1 (adds fallback/loud/determinism branches + tests).
- **Polish (Phase 6)**: Depends on all stories.

### Within Each User Story

- Tests written FIRST and confirmed failing before implementation (TDD, Constitution III).
- `danger_tier/1` and `@phrases` before `entries/1`; `entries/1` before `format/1`/`render/1`; render before the inventory wire-in.

### Parallel Opportunities

- T004 and T005 ([P], same new test file but independent test blocks) can be drafted together; T006 edits a different file ([P]).
- T013/T014 ([P]); T016/T017/T018 ([P]) are independent test additions.
- T021/T022 ([P]) are independent validations.
- Implementation tasks that touch `capability_render.ex` (T007–T011, T015, T019) are sequential (same file).

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 Setup → 2. Phase 2 Foundational → 3. Phase 3 US1 → **STOP & VALIDATE**: the discovery
   agent's capabilities render total, danger-ranked, and readable in the standing inventory. This
   alone delivers the permission-visibility value (the principle with no flag).

### Incremental Delivery

1. Setup + Foundational → backbone ready.
2. US1 → readable danger-ranked view live (MVP).
3. US2 → faithfulness/no-drift guaranteed.
4. US3 → determinism, agent-agnosticism, fallback, loud failure locked in.

---

## Notes

- [P] = different files or independent test blocks, no dependency on incomplete tasks.
- All tests are no-live-dependency (no network/model/Docker); registry-danger tests override
  `:agent_os, :connector_registry` and restore in `on_exit`.
- READ-ONLY scope: do not modify the gate, manifest schema, enforcement, or the registry's danger
  metadata; add no new connector/grant/capability type.
- Commit only on explicit request from the user.
