# Implementation Plan: Stage 2 Write the Manifest (write-manifest)

**Branch**: `013-write-manifest` | **Date**: 2026-06-30 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/013-write-manifest/spec.md)
**Input**: Feature specification from `/specs/013-write-manifest/spec.md`

## Summary
Deterministic projection from human-confirmed `ElicitedSpec` to v2 manifest schema. 
This pure, model-free function maps the spec's fields (purpose, capabilities, boundaries, spend) to the manifest fields, enforcing strict safety bounds (e.g. no ambient authority, no scope widening) and surfacing errors on under-specification. It outputs the machine-written manifest in YAML frontmatter/markdown format and generates a deterministic capability consent view from it.

## Technical Context

**Language/Version**: Elixir ~> 1.20  
**Primary Dependencies**: `jason`, `yaml_elixir`  
**Storage**: Substrate local filesystem (Markdown files with YAML frontmatter)  
**Testing**: `ExUnit` (tests matching requirements, deterministic runs)  
**Target Platform**: BEAM / OTP  
**Project Type**: Control plane library module  
**Performance Goals**: Pure projection latency < 10ms  
**Constraints**: Pure, deterministic mapping; no model calls; no agent-visible outputs.  
**Scale/Scope**: Stage 2 component of the v3 pipeline.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I: Simplicity First**: The implementation uses standard Elixir mapping and existing manifest models, avoiding any complex dependencies or engines.
- **Principle II: Explicit Scope Control**: The projector only handles the fields defined in the spec and manifest. No extra features, learning, or active agents are introduced.
- **Principle V: Strong Typing**: The implementation uses typed Elixir structs (`AgentOS.ElicitedSpec`, `AgentOS.Manifest`) and Dialyzer typespecs.
- **Principle VI: Loud Failures**: The projector raises explicit errors on unconfirmed specs, missing fields, or unknown connectors.
- **Principle IX: Substrate Owns State & Lifecycle**: The projector writes manifests to a substrate-only directory (`manifests/`), never mounting them to agent workloads.
- **Principle X: No Ambient Authority**: Capabilities are declared and constrained by boundaries, not self-conferred. Danger classification is left to the registry.
- **Principle XII: Enforcement Precedes Generation**: The emitted manifest parses and validates under the existing `AgentOS.Manifest.load/1` and gate.

## Project Structure

### Documentation (this feature)

```text
specs/013-write-manifest/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
└── contracts/           # Phase 1 output (/speckit-plan command)
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── manifest/
    │   └── projection.ex   # NEW — Manifest projection implementation
    └── manifest.ex         # Modified to expose helpers if needed

test/
└── agent_os/
    └── manifest/
        └── projection_test.exs # NEW — Tests for projection and consent rendering
```

**Structure Decision**: Option 1: Single project (DEFAULT), adding the projection module nested inside `lib/agent_os/manifest/` and its unit tests under `test/agent_os/manifest/`.

## Complexity Tracking

*No violations to justify.*
