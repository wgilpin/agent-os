# Implementation Plan: Agent Lifecycle Controls

**Branch**: `042-agent-lifecycle-controls` | **Date**: 2026-07-09 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/042-agent-lifecycle-controls/spec.md`

## Summary

Add per-agent lifecycle controls (pause, resume, delete, edit spend cap, edit triggers) to the
read-only `/inventory` LiveView. All mutations flow through one new substrate seam,
`AgentOS.AgentLifecycle`, keeping the web layer free of direct registry/filesystem/manifest
writes. The `DeploymentRegistry` gains `mark_active/1` and `delete/1` (staying the sole writer to
the `"deployments"` store, Constitution IX). `TriggerArming` gains per-agent timer-ref tracking
plus `disarm/1` and `rearm/1` so trigger edits and deletes take effect without a reboot. The
`InventoryLive` view gains Pause/Resume/Delete buttons and a per-agent edit panel (spend cap +
full trigger-list editing via a draft-based, JS-free row editor), following the existing
`test_fire` event pattern. *(Scope extension after user trial: trigger editing widened from
"change existing time values" to full add/remove/retype — see tasks.md Phase 6b.)*

## Technical Context

**Language/Version**: Elixir ~1.16 / OTP 26 (BEAM control plane)
**Primary Dependencies**: Phoenix 1.7, Phoenix.LiveView 0.20, Exqlite (StateStore backend), YamlElixir
**Storage**: Single-writer `StateStore` GenServers (SQLite-backed term store) + git-backed markdown files (`manifests/<name>.md`, `agents/<name>/`, `data/run_log.md`). No external DB.
**Testing**: ExUnit, hermetic (temp-dir StateStores, injected `schedule_fn`/`now_fn`). No live remote calls (Constitution IV).
**Target Platform**: Local BEAM node serving a Phoenix LiveView dashboard.
**Project Type**: Elixir/OTP control plane with a Phoenix LiveView web layer (`lib/agent_os/`, `lib/agent_os_web/`).
**Performance Goals**: N/A — single-owner prototype dashboard; actions are interactive, not high-throughput.
**Constraints**: No inline JS (global rule); no external DB; single-writer-per-store; manifest is privileged-read (never crosses the port boundary).
**Scale/Scope**: Handful of generated agents; one inventory page; five lifecycle operations.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Simplicity First** — PASS. No new dependencies, no new processes. Reuses the existing
  registry, StateStore `{:delete_in, …}` action, `Manifest.load` + `Projection.write` round-trip,
  and `Process.send_after`/`Process.cancel_timer`. One new plain module (`AgentLifecycle`) that
  orchestrates existing primitives.
- **II. Explicit Scope Control** — PASS. Scope is exactly the four approved stories, plus a
  user-requested extension (full trigger add/remove/retype, tasks.md Phase 6b) after trying the
  UI. Explicitly out of scope (and not built): editing grants/capabilities, cancelling
  in-flight runs, purging run-log history, non-daily time cadences, the legacy
  `AgentOS.Scheduler`.
- **III. Test-Driven Backend** — PASS with a documented UI carve-out. All new backend logic
  (`DeploymentRegistry.mark_active/delete`, `TriggerArming.disarm/rearm` + stale-fire guard, the
  whole `AgentLifecycle` module) is built test-first. Per this principle, the LiveView is **not**
  unit-tested; it is covered by the manual walkthrough in `quickstart.md`. The view is kept
  deliberately thin (every mutation delegates to the tested `AgentLifecycle` seam), so the untested
  surface carries no business logic. This is a deliberate deviation from the design brief's
  "LiveView test" line — see Complexity Tracking.
- **IV. No Live Dependencies in Tests** — PASS. All tests use temp-dir StateStores and injected
  clock/scheduler fns; no remote calls.
- **V. Strong Typing, No Bare Maps** — PASS. Reuses the typed `DeploymentRecord`, `Manifest`,
  `Spend` structs. `AgentLifecycle` functions carry `@spec`s returning `:ok | {:error, reason}`.
- **VI. Loud Failures** — PASS. Every no-op/failure path logs with context (matching the existing
  `mark_inactive` warning style) and returns a typed error for flash rendering.
- **VII. Self-Documenting** — PASS. Every new function gets a `@doc`; non-obvious blocks (delete
  ordering, stale-fire guard) get intent comments.
- **VIII. Legibility** — PASS. The inventory remains the standing legible view; lifecycle actions
  refresh it in place and broadcast so other sessions converge.
- **IX. Substrate Owns State & Lifecycle** — PASS (central to this feature). The registry stays the
  **sole writer** to `"deployments"`; `delete/1` and `mark_active/1` live inside it. The web layer
  writes nothing directly — it calls `AgentLifecycle`, which calls the registry. No agent-specific
  vocabulary leaks into the kernel (operations are generic over `agent_name`).
- **X / XI. No Ambient Authority / Deterministic Gate** — PASS. Lifecycle controls gate *dispatch*
  and edit *declared* config (cap, schedule); they confer no capability and never let an LLM widen
  authority. Cap/schedule edits rewrite the manifest, which the gate re-reads at enforcement time.
- **XII. Enforcement Precedes Generation** — N/A (no change to the enforcement/generation ordering).

**Result: PASS.** One justified deviation (UI not unit-tested) recorded below.

## Project Structure

### Documentation (this feature)

```text
specs/042-agent-lifecycle-controls/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output (manual walkthrough / verification)
├── contracts/
│   └── agent-lifecycle.md   # AgentLifecycle + registry + TriggerArming public contract
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

```text
lib/agent_os/
├── deployment_registry.ex     # + mark_active/1, + delete/1 (sole writer to "deployments")
├── agent_lifecycle.ex         # NEW — the single lifecycle seam the UI calls
├── trigger_arming.ex          # armed → %{agent => %{at => timer_ref}}; + disarm/1, + rearm/1
├── manifest.ex                # (read) load/parse
├── manifest/projection.ex     # (read) serialize/write round-trip for cap/schedule edits
└── state_store.ex             # (read) {:delete_in, path} action reused for state cleanup

lib/agent_os_web/
└── live/inventory_live.ex     # + Pause/Resume/Delete buttons, edit panel, handlers

test/agent_os/
├── deployment_registry_test.exs   # + mark_active / delete cases
├── trigger_arming_test.exs        # + disarm / rearm / stale-fire-guard cases
└── agent_lifecycle_test.exs       # NEW — pause/resume/delete/update_spend_cap/update_schedule
```

**Structure Decision**: Existing Elixir/OTP + Phoenix layout. Backend logic lives under
`lib/agent_os/` with mirrored ExUnit tests under `test/agent_os/`; the web layer is the single
`InventoryLive` module under `lib/agent_os_web/live/`. No new directories.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| UI (`InventoryLive`) is not unit-tested, deviating from the approved design brief's "LiveView test" line | Constitution III explicitly forbids unit tests for frontend components — they are covered by manual walkthrough instead. (Legacy LiveView tests exist under `test/agent_os_web/` for earlier features and are kept green, but no new ones are added.) | Writing new `Phoenix.LiveViewTest` coverage would violate Constitution III. Mitigation: all logic sits in the fully-unit-tested `AgentLifecycle` seam, leaving the view a thin dispatch layer; UI is verified by the `quickstart.md` manual walkthrough. |
