# Implementation Plan: Conformance Auditor

**Branch**: `010-conformance-auditor` | **Date**: 2026-06-30 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/010-conformance-auditor/spec.md`

## Summary

Add a substrate-side **conformance auditor** that reads the legible run-log (`data/run_log.md`)
and the agent's stated purpose, and raises FLAG-ONLY conformance/trust flags it renders as
provenance in the standing inventory. It catches exactly the signals the deterministic gate is
structurally blind to — omission/health (Leg 1) and the aggregate "reaching for what it wasn't
cleared for" pattern (Leg 2) — and never re-flags what the gate already enforces per action.

Per the clarification session the auditor runs as a **scheduled, persisted pass**: a daily
self-rescheduling GenServer computes a per-agent verdict over the last N=20 run records, persists
it to a single-writer `StateStore`, and on a newly-raised/escalated flag emits a notification-only
admin alert for a future admin UI. The inventory renders the persisted verdict. The semantic-drift
leg (LLM) is out of scope. The pure decision logic is a separate, fully unit-tested module; the
GenServer and inventory render are thin wrappers around it.

## Technical Context

**Language/Version**: Elixir (BEAM/OTP), matching the existing control plane. No Python change.
**Primary Dependencies**: OTP only (`GenServer`, `Supervisor`, `Logger`) + existing AgentOS
modules: `RunLog`, `StateStore`, `Inventory`, `CapabilityRender`, `Manifest`, `Scheduler` (pattern
to mirror), `Alerter` (mechanism to mirror, not reuse — see research).
**Storage**: reads `data/run_log.md`; persists verdicts to a new single-writer `StateStore` named
`"conformance"` (term-file, `data/conformance.term`); admin alerts append to a **separate** git-backed
markdown log `data/admin_alerts.md` (NOT the run-log — feedback-loop avoidance).
**Testing**: ExUnit, fixture run-logs (no live deps); Dialyzer clean; `mix format` + Credo clean.
**Target Platform**: BEAM (local prototype).
**Project Type**: Single project (Elixir control plane under `lib/agent_os`).
**Performance Goals**: Trivial — parse ≤20 trailing log lines per agent per day. No targets needed.
**Constraints**: Deterministic (no LLM, no wall-clock in the verdict); agent-agnostic (keyed by
manifest/agent name, no agent domain vocabulary in `lib/`); FLAG-ONLY (no pass/gate code path); the
admin alert must not pollute the run-log health signal.
**Scale/Scope**: One hand-written discovery agent today; verdict map keyed by agent name to generalize.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Simplicity First | PASS (with note) | Pure decision logic is one module + two structs; the GenServer + new store + alert log are the **minimal** shape of the explicitly-requested scheduled/persisted/alert behaviour (clarify session). No framework. See Complexity Tracking. |
| II. Explicit Scope Control | PASS | Every part traces to a FR; the scheduled/persisted/alert scope was explicitly chosen by the user in clarification. Semantic-drift leg explicitly deferred. |
| III. Test-Driven Backend | PASS | Pure `audit/2`, the run-record parser, and the "should-alert/escalation" decision are built test-first. Inventory render + GenServer wiring covered by integration assertions, not unit tests. |
| IV. No Live Dependencies in Tests | PASS | Everything is fixture run-logs and in-memory structs. No remote/LLM calls anywhere. |
| V. Strong Typing, No Bare Maps | PASS | `Verdict` and `Flag` structs with `@type`; parsed records are a typed struct; Dialyzer clean. |
| VI. Loud Failures | PASS | A malformed/unparsable run-log line is skipped **with a `Logger.warning`** — never silently dropped. |
| VII. Self-Documenting | PASS | `@moduledoc`/`@doc` on every module/function; intent comments on non-obvious logic. |
| VIII. Legibility (no flag) | PASS — core purpose | Verdict is read from the inventory without asking the agent; it strengthens the standing legibility surface. |
| IX. Substrate Owns State & Lifecycle | PASS | Verdict persisted via a single-writer `StateStore`; scheduling is a substrate GenServer; logs are git-backed append-only markdown; no external DB. Auditor is agent-agnostic (keyed by agent name from the manifest). |
| X. No Ambient Authority | PASS | The auditor is a substrate component (not the agent); it reads the manifest **purpose** privileged-side, never confers a capability and never classifies danger. |
| XI. Deterministic Gate Is the Only Firewall | PASS — headline invariant | Auditor is a smoke detector: flag-only, alert notification-only, no code path returns a pass or crosses/gates the boundary (FR-001/FR-013). Asserted by a dedicated test. |
| XII. Enforcement Precedes Generation | PASS | Generation-independent; built/proven on the existing hand-written agent. |

**Gate result: PASS.** No unjustified violations.

## Project Structure

### Documentation (this feature)

```text
specs/010-conformance-auditor/
├── plan.md              # This file
├── research.md          # Phase 0 — field-mapping & design decisions
├── data-model.md        # Phase 1 — Verdict / Flag / RunRecord
├── quickstart.md        # Phase 1 — how to run the audit + read the verdict
├── contracts/
│   ├── auditor-api.md    # ConformanceAuditor public API + thresholds
│   └── inventory-render.md # Rendered provenance block contract
└── checklists/
    └── requirements.md  # Spec quality checklist (from /speckit-specify)
```

### Source Code (repository root)

```text
lib/agent_os/
├── conformance_auditor.ex            # NEW — pure audit/2 + run_pass/1 orchestration
├── conformance_auditor/
│   ├── verdict.ex                    # NEW — Verdict struct + typespec
│   ├── flag.ex                       # NEW — Flag struct + typespec
│   ├── scheduler.ex                  # NEW — daily self-rescheduling GenServer → run_pass/1
│   └── alert.ex                      # NEW — notification-only admin alert sink (Logger + admin_alerts.md)
├── run_log.ex                        # EDIT — add read_records/2 (multi-record parser)
├── inventory.ex                      # EDIT — render persisted conformance verdict block
└── application.ex                    # EDIT — add "conformance" StateStore + auditor Scheduler child

test/agent_os/
├── conformance_auditor_test.exs      # NEW — pure logic: legs, thresholds, multi-flag, clear, insufficient, flag-only, determinism
├── conformance_auditor/
│   └── alert_test.exs                # NEW — alert decision + writes to admin_alerts.md, NOT run_log.md
├── run_log_test.exs                  # EDIT — read_records/2 parsing (incl. malformed-line skip)
└── inventory_test.exs                # EDIT — verdict provenance appears in render
```

**Structure Decision**: Single Elixir project. The pure decision logic (`ConformanceAuditor`,
`Verdict`, `Flag`) is isolated from the side-effecting wrappers (`Scheduler` GenServer, `Alert`
sink, the `StateStore` persistence, and the `Inventory` render) so the load-bearing behaviour is
unit-tested in isolation, mirroring how `CapabilityRender` separates `Entry` from the renderer.

## Phase 0: Outline & Research

See [research.md](research.md). It resolves the design decisions that are not free choices:

1. **Run-log → signal field mapping** (the crux of correctness and non-redundancy):
   - **Leg 1 quiet** ← trailing consecutive records with `actions=0`.
   - **Leg 1 sick** ← any record `status=alert` in window, or a strictly-rising `items_dropped` share in the latest record.
   - **Leg 2a denied-approval** ← records with `trigger=approval-resume` whose note is `denied`
     (a human-denied parked action) — **NOT** the gate's `rejected_count`, because per-action
     constraint rejection is enforcement the gate already owns (FR-003 non-redundancy).
   - **Leg 2b gate-breach** ← `breached_count > 0` or non-empty `gate_reasons` on any record.
2. **Feedback-loop avoidance**: the admin alert is mechanism-reuse of `Alerter` (Logger +
   append-only markdown) but to a **separate** `data/admin_alerts.md`, never a `status=alert` line
   in the run-log (which the sick signal reads).
3. **Window definition**: the last N=20 records that carry `status=` (digest lines excluded),
   default configurable; quiet streak counts only the trailing run, breach is a tripwire.
4. **Scheduling shape**: a dedicated daily self-rescheduling GenServer mirroring `Scheduler`,
   calling `ConformanceAuditor.run_pass/1`, rather than extending `Scheduler` (separation of the
   run trigger from the audit trigger) or coupling into the run pipeline.
5. **Escalation semantics for the alert**: alert only on a *newly raised or escalated* flag vs the
   previously persisted verdict — comparing new flags against the stored verdict before overwrite.

## Phase 1: Design & Contracts

- [data-model.md](data-model.md): `Verdict`, `Flag`, and the parsed `RunRecord`, with field types,
  the flag taxonomy, status lifecycle (clean / flagged / insufficient_data), and clear semantics.
- [contracts/auditor-api.md](contracts/auditor-api.md): the `ConformanceAuditor` public surface
  (`audit/2` pure, `run_pass/1` orchestration), the thresholds, and the FLAG-ONLY invariant.
- [contracts/inventory-render.md](contracts/inventory-render.md): the rendered provenance block the
  inventory appends next to the capability view.
- [quickstart.md](quickstart.md): how to trigger an audit pass, read the persisted verdict, and see
  the inventory + admin-alert output.
- Agent context: the `<!-- SPECKIT -->` block in `CLAUDE.md` is updated to point at this plan.

## Complexity Tracking

> Constitution Check passed; this records the one tension worth justifying.

| Decision | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Dedicated `Scheduler` GenServer + `"conformance"` StateStore + separate `admin_alerts.md` | The user explicitly chose (clarification) a **scheduled, persisted** pass that **emits an admin alert**, over the render-time pure function. This is the minimal OTP shape for that request. | A render-time pure function (no process, no store) is simpler but was explicitly **not** chosen; folding the audit into the run pipeline (option C) was also rejected by the user and would couple the auditor to the agent run, weakening the "above the gate, reads traces" stance. |
