# Implementation Plan: Spend Metering and Real Kill-on-Breach

**Branch**: `005-spend-metering` (work lands on `master`, per 002/003/004 convention) | **Date**: 2026-06-29 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/005-spend-metering/spec.md`

## Summary

Complete the third axis of the enforcement envelope (spend) by making the already-declared
`{cap, window, on_breach}` spend struct fully load-bearing. The gate already computes a
per-action cost and the `{:breach, :spend}` decision; the persisted single-writer
`spend_ledger` store already holds a per-agent entry of `{spent, window_start}`. This feature
adds the four pieces that are still missing:

1. **Window reset** — `window_start` becomes load-bearing. A new pure helper module
   `AgentOS.SpendLedger` computes, given a stored entry, the current time, and the window, the
   *windowed* entry: if the current time is past `window_start + duration(window)`, `spent`
   resets to zero and the window re-anchors. `RunWorker` applies (and persists) this reset
   **before** the gate check; `Inventory` applies it for display. `daily` is the only window.
2. **on_breach dispatch** — `RunWorker`'s breach branch stops hardcoding the kill and instead
   dispatches on `manifest.spend.on_breach`. `:kill` is the only implemented value; the whole
   batch is dropped (FR-012) and the run stops.
3. **Restart-exemption** — the breach-triggered kill returns a distinct intentional-stop
   signal `{:killed, :spend_breach}` (not `:ok`, not `{:error, _}`). `RunSupervisor.run_loop`
   and `RunWorker.run_and_raise` gain a clause treating it as a terminal non-fault: no restart,
   no Alerter. A genuine crash/OOM still returns `{:error, _}` and still restarts once.
4. **Visibility** — `Inventory.render` reads the `spend_ledger` snapshot and reports the
   agent's `spent / cap / window` for the current window, without contacting the agent.

The spend meter stays exactly where it is (FR-013): the gate computes cost, `RunWorker`
increments the ledger post-gate. Both `RunWorker` and `Inventory` take an injectable `:now`
(default `DateTime.utc_now/0`) so window rollover is testable without waiting on a real clock
(FR-010). This was tracked as User Story 4 within 002-manifest-enforcement; it is carved into
its own spec/plan the way US2 became 003 and US3 became 004.

## Technical Context

**Language/Version**: Elixir ~> 1.20 (control plane only). No Python change.
**Primary Dependencies**: existing only — OTP `GenServer` (`StateStore`, `RunSupervisor`),
`DateTime` from stdlib for window arithmetic. No new deps.
**Storage**: the existing persisted single-writer `spend_ledger` term-file store
(`data/spend_ledger.term`, gitignored). No new store, no schema migration — the entry already
carries `spent` and `window_start`; this feature starts honouring `window_start`.
**Testing**: ExUnit, deterministic only. New `test/agent_os/spend_ledger_test.exs` (pure window
math), new spend/window/breach cases in `test/agent_os/run_supervisor_test.exs` driving the
meter through `run_once`/`worker_fn` with an injected `:now`, restart-exemption vs.
crash-restart cases, and spend-visibility cases in `test/agent_os/inventory_test.exs`. No
Docker, no live LLM, no external service (Constitution IV); costs come from the connector
registry, the clock is injected.
**Target Platform**: Linux/macOS host (unchanged).
**Project Type**: Single project — BEAM control plane + Python agent workload across a port
boundary. This feature is control-plane only; nothing crosses the boundary.
**Performance Goals**: N/A — window math is O(1) `DateTime` arithmetic on the once-per-run
gate path; off any hot loop.
**Constraints**: No change to the gate's allow/deny/recipient/method logic or the cost model
(FR-011). The kill must be a *real* stop (no action executes) and distinguishable from a crash
(FR-005/006/007). Window is FIXED/resetting, not rolling. Spend visibility reads persisted
state only, never the agent (Principle VIII).
**Scale/Scope**: One new pure module (`AgentOS.SpendLedger`), edits to three existing modules
(`RunWorker`, `RunSupervisor`, `Inventory`). ~1 module of new code + three edited modules +
four test touch-points. No new supervision-tree entry.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Simplicity First | PASS | One small pure helper module + edits to three modules. Window math is plain `DateTime` arithmetic; no scheduler, no timer process, no new store, no abstraction beyond `current_entry/3` and an `on_breach` dispatch. Clock is a default arg, not a Clock behaviour. |
| II. Explicit Scope Control | PASS | Exactly US4 from the 002 roadmap. No triggers (03-05), no world-B (03-06), no new on_breach values, no rolling windows, no gate-logic change (03-01). Out-of-scope fenced in spec. |
| III. Test-Driven Backend | PASS | Pure window math and the run-worker/supervisor behaviour are backend logic — built test-first (red→green). Inventory render text is asserted via integration-style string checks (existing pattern), not unit-mocked UI. |
| IV. No Live Dependencies in Tests | PASS | Costs from the connector registry, a small cap, and an injected `:now`. No Docker, no live LLM, no network. Window rollover tested by advancing the injected clock. |
| V. Strong Typing, No Bare Maps | PASS | `SpendLedger` carries a `@type entry` typespec and `@spec`s; `run_once/1`'s return type is widened to include `{:killed, :spend_breach}`. Dialyzer clean. The ledger entry keeps its existing on-disk map shape but is typed and accessed through the helper. |
| VI. Loud Failures | PASS | The kill logs a distinct `status=killed failure_cause=spend_breach` run-log line (already present) plus the dispatched `on_breach`. A window reset logs an info line. No silent swallow. |
| VII. Self-Documenting | PASS | Every new function gets a `@doc`/`@moduledoc`; the window-boundary and dispatch blocks get intent comments. |
| VIII. Legibility | PASS | This feature *strengthens* legibility: per-agent spend becomes readable on the standing inventory from persisted state, without asking the agent. |
| IX. Substrate Owns State & Lifecycle | PASS | `StateStore` remains the single writer for `spend_ledger`; `SpendLedger` is a pure read/normalize helper, not a second writer. No agent-specific vocabulary enters `lib/agent_os/` — `agent_name` is derived from the manifest path, `window` from the manifest, cost from the registry. |
| X. No Ambient Authority | PASS | The cap, window, and on_breach are read from the manifest (privileged-read, gate-only); the agent never sees or sets them. Cost/danger stay fixed by the connector registry, not the manifest author. |
| XI. Deterministic Gate Is the Only Firewall | PASS | Enforcement stays deterministic and on the substrate side; the breach decision is the gate's, the kill is the substrate's. No LLM involved in any decision. |
| XII. Enforcement Precedes Generation | PASS | This is enforcement (v2) work; no generation (v3) anything. |

**Result**: PASS. No violations; Complexity Tracking table omitted.

## Project Structure

### Documentation (this feature)

```text
specs/005-spend-metering/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── spend-ledger.md      # current_entry/3, duration_seconds/1, rolled_over?/3
│   ├── run-worker.md        # run_once/1 return contract + on_breach dispatch
│   └── inventory-spend.md   # per-agent spent/cap/window render contract
├── checklists/
│   └── requirements.md  # Spec quality checklist (from /speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/agent_os/
├── spend_ledger.ex          # NEW — pure window math + entry normalization
├── run_worker.ex            # EDIT — inject :now; apply+persist window reset before gate;
│                            #        dispatch on_breach; return {:killed, :spend_breach}
├── run_supervisor.ex        # EDIT — run_loop clause: {:killed, _} => intentional stop, no restart
├── inventory.ex             # EDIT — read spend_ledger; render spent/cap/window for current window
├── gate.ex                  # UNCHANGED (FR-011)
├── connector.ex             # UNCHANGED (cost source)
└── manifest/spend.ex        # UNCHANGED ({cap, window, on_breach} struct)

test/agent_os/
├── spend_ledger_test.exs    # NEW — pure: duration, rollover boundary (inclusive/exclusive), reset
├── run_supervisor_test.exs  # EDIT — cap boundary, over-cap kill, reset-after-rollover,
│                            #        restart-exemption-on-breach, crash-still-restarts
└── inventory_test.exs       # EDIT — per-agent spent/cap/window; zero after reset; no agent contact
```

**Structure Decision**: Single project, control-plane only. One new pure module
(`AgentOS.SpendLedger`) holds the only genuinely new logic (window math), shared by both the
enforcement path (`RunWorker`) and the visibility path (`Inventory`) so the windowed-entry
semantics are defined once. The remaining changes are surgical edits to existing modules at
their existing seams. No new supervision-tree process is introduced — `spend_ledger` is already
started in `application.ex`.

## Phase 0: Research

See [research.md](./research.md). All spec clarifications were resolved during `/speckit-specify`
(kill granularity = drop whole batch; meter location = gate/run-worker). The remaining research
items are design decisions internal to this plan: window-anchor semantics, the clock-injection
mechanism, the intentional-stop signal shape, and where the shared windowed-entry helper lives —
all resolved in research.md with no NEEDS CLARIFICATION remaining.

## Phase 1: Design & Contracts

- **Data model**: [data-model.md](./data-model.md) — the Spend Ledger Entry (persisted), the
  windowed view computed from it, the Spend Constraint (manifest), and the Breach Stop Signal.
- **Contracts**: [contracts/](./contracts/) — the pure `SpendLedger` API, the `run_once/1`
  return contract with on_breach dispatch, and the inventory spend-render contract.
- **Quickstart**: [quickstart.md](./quickstart.md) — how to exercise the windowed cap, the
  breach kill, the restart-exemption, and the visibility render deterministically.
- **Agent context**: the `<!-- SPECKIT -->` block in `CLAUDE.md` is updated to point at this plan.

**Post-Design Constitution Re-Check**: PASS — the design adds one pure module and three
surgical edits; no new dependency, store, or process; legibility strengthened; gate logic
untouched.

## Complexity Tracking

No constitution violations — table omitted.
