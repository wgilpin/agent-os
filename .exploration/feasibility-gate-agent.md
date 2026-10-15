# Front-Door Feasibility & Gap-Planner Agent

## Problem
When the operator submits a real-world agent request (such as checking Bath property listings every morning against architectural and EV-parking criteria while filtering out previously rejected listings), the current Elicitor only receives registered connector names and descriptions (`capability_vocabulary/0`). Because it cannot tell which connectors are unimplemented stubs (`web_search`, `gmail_read`, `gmail_draft`), which credentials are missing, or which substrate/UI capabilities do not exist yet, it either happily elicits and generates a doomed agent that fails at runtime or dead-ends with a refusal instead of telling the operator what to build next in Agent OS.

## Proposed change
Introduce a separate, single-turn Feasibility / Planner agent directly in front of the Elicitor at the start of the agent-creation flow. When the operator enters a purpose, the substrate passes the Feasibility agent a curated, read-only snapshot of Agent OS's actual capabilities (`lib/agent_os/connector/*.ex` source files, `manifest.ex`, `router.ex`, and boolean credential-presence flags—never secret values). The agent returns one of three verdicts:
1. **`full`** — Agent OS can genuinely support the full request today; the UI proceeds straight into the Elicitor session without an extra step.
2. **`partial`** — Parts of the request are missing or stubbed, but a useful subset can run today; the UI explains the gap and offers two choices: **"Run the pared-back version now"** (starts the Elicitor seeded with the scoped-down purpose) or **"Write me a spec for the changes"** (renders a concise, high-level product brief on screen ready to paste into `sdlc:specify`).
3. **`blocked`** — No viable pared-back version exists; the UI explains what is missing and offers **"Write me a spec for the changes"** to display the `sdlc:specify` brief on screen.

## Key decisions made during exploration
- **Separate agent in front of the Elicitor (`feasibility` -> `elicitor`)**: Keeps architectural/codebase awareness and gap-planning in a dedicated gatekeeper (`agents/feasibility/`) while keeping the Elicitor focused strictly on turning a known-feasible purpose into a minimal manifest.
- **Three-state verdict (`full` | `partial` | `blocked`)**: Avoids offering a meaningless "pared-back" option when the core capability is completely absent or stubbed (e.g., a property search when `web_search` is a stub).
- **Two actionable choices on non-full verdicts**: "Run the pared-back version now" (for `partial`) vs. "Write me a spec for the changes" (for `partial` and `blocked`).
- **High-level `sdlc:specify` brief rendered on screen only**: The spec output does not need low-level implementation details because `sdlc:specify` will inspect the repo during planning; rendering it directly on screen avoids writing extra files to disk.
- **Single-turn pre-bundled context on `stdin` rather than a multi-turn code-reading tool**: The Elixir substrate deterministically bundles `lib/agent_os/connector/*.ex`, `lib/agent_os/manifest.ex`, `lib/agent_os_web/router.ex`, and boolean credential presence from `AgentOS.CredentialSource` into the `stdin` JSON payload. This requires zero tool authority (`grants: []`), prevents arbitrary file probing or secret exposure, and completes in one LLM call.

## Open questions
- None blocking specification.

## Red-team findings
The idea survived red-teaming. Two main challenges were considered and resolved:
1. **Why a separate agent instead of folding feasibility into Turn 1 of the Elicitor?** Because determining real feasibility requires inspecting connector implementation code and substrate surfaces (and producing an `sdlc:specify` brief for Agent OS itself), separating the architectural gatekeeper from the manifest Elicitor preserves a clean separation of concerns: the Elicitor never sees codebase internals, and only runs once a feasible (or pared-back) purpose is chosen.
2. **Should the agent have an interactive code-introspection tool?** Rejected in favor of pre-bundled `stdin` context. Since connector and manifest source files total ~20KB and only change at code-deploy time, bundling them deterministically on `stdin` is both simpler (one LLM call, no new tool-loop plumbing) and safer (`grants: []`, no filesystem traversal or `.env` access).

## Feasibility flags
- The Feasibility agent must run through `AgentOS.InferenceBroker` under a system/setup token (similar to `elicitor` and `orchestrator`) and have a deterministic mock (`MOCK_FEASIBILITY` or test stub) to satisfy Constitution Principle IV (No Live Dependencies in Tests).

## Out of scope
- Multi-turn interactive code-browsing tools for the Feasibility agent.
- Writing the generated change spec to disk from the UI (on-screen display only).
- Automatically implementing the missing Agent OS connectors/features (handled downstream by the operator via `sdlc:specify`).

## Ready for /specify?
Yes.
