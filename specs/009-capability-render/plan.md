# Implementation Plan: Deterministic Capability Render

**Branch**: `009-capability-render` | **Date**: 2026-06-30 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/009-capability-render/spec.md`

## Summary

Add a substrate-side, pure-function render that turns an agent's manifest grants into a
faithful, total, danger-ranked, normie-readable view of what the agent is allowed to do. It
reads only the manifest grants and the connector capability registry (both already
substrate-side), maps each grant's generic capability name to a hard-coded human-readable
phrase, derives each grant's danger tier deterministically from the registry's existing danger
metadata (`mutating?` / `requires_approval?` / `credential` / `cost`), and emits one entry per
grant. It replaces the raw `inspect(manifest.grants)` line in `AgentOS.Inventory.render/1`. No
LLM, no network, no Docker — a single deterministic Elixir module plus a one-line swap in the
inventory.

## Technical Context

**Language/Version**: Elixir/BEAM (control-plane substrate); matches existing `lib/agent_os/`.
**Primary Dependencies**: None new. Reads `AgentOS.Manifest` (grants), `AgentOS.Manifest.Grant`,
and `AgentOS.Connector` (registry). No Python, no model SDK.
**Storage**: N/A — pure function over in-memory manifest + registry. No state written.
**Testing**: ExUnit (`mix test`), no live dependencies (no network/model/Docker), per Constitution IV.
**Target Platform**: BEAM substrate (same as the rest of the control plane).
**Project Type**: Single Elixir app (substrate kernel module + test).
**Performance Goals**: Not performance-sensitive; a manifest has a handful of grants. Render is O(grants).
**Constraints**: Deterministic (byte-identical output for identical input); `mix format` + Credo clean;
every function has a purpose comment.
**Scale/Scope**: One new module (`AgentOS.CapabilityRender`), one new test file, and a one-line edit
to `AgentOS.Inventory.render/1`. The existing discovery agent's two grants (`kv_append`,
`external_send`) are the acceptance anchor.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Compliance |
|-----------|------------|
| I. Simplicity First | ✅ One pure module + a one-line inventory swap. No new deps, no abstraction beyond a phrase map and a tier function. |
| II. Explicit Scope Control | ✅ Reads-only; out-of-scope items (review modes, deploy, auditor, generation, registry/gate/schema changes) enumerated in spec and not touched. |
| III. Test-Driven Backend | ✅ TDD: write render tests (faithful/total/danger/deterministic) first, then implement. |
| IV. No Live Dependencies in Tests | ✅ Pure function; tests construct manifests + override the registry via `Application.put_env(:agent_os, :connector_registry, ...)`. No network/model/Docker. |
| V. Strong Typing, No Bare Maps | ✅ Consumes typed `%AgentOS.Manifest.Grant{}` and the registry's typed capability maps; render returns a typed struct list (`%AgentOS.CapabilityRender.Entry{}`) before string formatting. |
| VI. Loud Failures | ✅ Registry lookup failure at render time raises/surfaces loudly (FR-011); missing phrase falls back deterministically but is never silently dropped. |
| VII. Self-Documenting Through Comments | ✅ Every function gets a purpose comment; the danger-tier rule is commented at its definition. |
| VIII. Legibility (no flag) | ✅ This feature *is* legibility — capabilities read from the standing inventory without asking the agent. |
| IX. Substrate Owns State / Agent-Agnostic | ✅ Phrase map keyed by GENERIC capability name (`kv_append`, `external_send`); no agent's domain vocabulary ("roster"/"digest") hard-coded. Render is substrate-side, pure. |
| X. No Ambient Authority | ✅ Danger is read from the registry only — never the manifest author, never invented by the render. The render classifies nothing; it looks up. |
| XI. Deterministic Gate Is the Only Firewall | ✅ No LLM, no credential touched. Render is deterministic and holds no capability. |
| XII. Enforcement Precedes Generation | ✅ Generation-independent; built on the existing hand-written agent. |

**Result**: PASS. No violations; Complexity Tracking not required.

## Project Structure

### Documentation (this feature)

```text
specs/009-capability-render/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── capability_render.md   # Phase 1 output — the render's public contract
├── checklists/
│   └── requirements.md  # From /speckit-specify
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/agent_os/
├── capability_render.ex   # NEW — the deterministic render (phrase map + danger tier + entry list/format)
├── inventory.ex           # EDIT — replace `GRANTS: #{inspect(manifest.grants)}` with the render
├── connector.ex           # READ-ONLY — danger metadata source (unchanged)
└── manifest/grant.ex      # READ-ONLY — grant struct (unchanged)

test/agent_os/
├── capability_render_test.exs   # NEW — faithful / total / danger-ranked / deterministic / fallback
└── inventory_test.exs           # EDIT — assert the rendered capability view appears (not raw structs)
```

**Structure Decision**: Single Elixir app, existing `lib/agent_os/` layout. The render is a new
kernel module `AgentOS.CapabilityRender` (sibling of `AgentOS.Inventory`), consumed by the
inventory. No new top-level directories.

## Phase 0 — Research

See [research.md](research.md). Key resolved decisions:

- **Phrase mapping lives in the new render module**, not in the registry — keyed by generic
  capability name. This honours "no change to the registry's danger metadata" (a phrase is not
  danger metadata) while keeping the lookup substrate-owned and mechanical.
- **Danger tier is derived from the registry via `Connector.registry()`** (the env-overridable
  accessor), because that is the same accessor the enforcement path (`effector.ex`,
  `run_worker.ex`) reads at runtime — guaranteeing the displayed danger cannot drift from the
  enforced cost/credential behaviour. Three tiers: `:read_only` < `:local` < `:external`.
- **Render returns typed entries, then formats to text**, so totality/faithfulness are testable
  at the structured level and formatting is a thin, deterministic layer.

## Phase 1 — Design & Contracts

- [data-model.md](data-model.md) — `CapabilityRender.Entry` struct, danger-tier rule, phrase-map shape.
- [contracts/capability_render.md](contracts/capability_render.md) — public function contract for
  `AgentOS.CapabilityRender`.
- [quickstart.md](quickstart.md) — how to run the render and the tests; the discovery-agent worked example.

## Complexity Tracking

No constitution violations. Section intentionally empty.
