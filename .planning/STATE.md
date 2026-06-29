# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-27)

**Core value:** The control plane is the product — everything an agent is and does is declared, enforced, observable, and killable; never "ask the agent."
**Current focus:** Phase 3 — Manifest Enforcement (v2)

## Current Position

Phase: 3 of 4 (Manifest Enforcement — v2)
Status: In progress — the gate, provisioning, and manifest-invisibility have landed; spend/triggers/world-B remain.

**➡️ NEXT: roadmap plan `03-03` — Credential proxy (US3).** No LLM-running component holds a
mutating credential; the proxy holds caps and injects at the chokepoint. P1, load-bearing.
This is the next thing to `/speckit-specify` (carve into spec `004-credential-proxy`, like US2 → 003).

Phase 3 plan status (6 plans, roadmap order):
- [x] 03-01 Gate validates every action vs grants/constraints — spec 002
- [x] 03-02 Substrate provisions from enforced manifest — spec 002
- [x] (US2) Manifest invisible to the agent — boundary invariant — spec 003 (commit a78afe9)
- [ ] 03-03 Credential proxy — **NEXT**
- [ ] 03-04 Spend {cap, window, on_breach} + kill-on-breach
- [ ] 03-05 Event/message triggers + approval-as-event ("ph5")
- [ ] 03-06 World-B verification — gate holds vs a hostile agent (last; the real "v2 done" bar)

Last activity: 2026-06-29 — boundary invisibility invariants (commit a78afe9); reconciled stale tracking.

Progress: [██████░░░░] Phases 1–2 complete; Phase 3 ~half (2/6 plans + US2 invariant).

## Numbering decoder (read this before asking "what is phN")

One piece of work has up to four names. They are NOT the same scale — always anchor on the **roadmap plan**:

| Roadmap plan | Roadmap phase | Spec folder | `002/tasks.md` phase / User Story |
|---|---|---|---|
| 03-01 gate | Phase 3 | 002 | Phase 3 / US1 |
| 03-02 provisioning | Phase 3 | 002 | Phase 2 (foundational) |
| (invisibility) | Phase 3 | **003** | Phase 4 / US2 |
| 03-03 credential proxy | Phase 3 | 004 (next) | Phase 5 / US3 |
| 03-04 spend | Phase 3 | — | Phase 6 / US4 |
| 03-05 triggers ("ph5") | Phase 3 | — | Phase 7 / US5 |
| 03-06 world-B | Phase 3 | — | Phase 8 / US6 |

"ph5" historically meant `002/tasks.md` Phase 5 (US3, credential proxy) in one session and roadmap
plan 03-05 (triggers) in another — that ambiguity is the whole problem. **Going forward, refer to
work by roadmap plan id (e.g. "03-03"), not "phN".**

## Performance Metrics

**Velocity:**
- Total plans completed: 0
- Average duration: — min
- Total execution time: 0.0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

**Recent Trend:**
- Last 5 plans: —
- Trend: —

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table (18 decisions, all PROPOSED —
none locked; promote to a formal ADR to lock). Recent decisions affecting current work:

- [Phase 1]: Substrate owns all state + scheduling; single-writer GenServer for roster/trust.
- [Phase 1]: Agents are invocation-scoped pure functions (run once, die); triggers are data.
- [Roadmap]: Enforcement (v2) precedes generation (v3) — HARD, cannot be reshuffled.

### Pending Todos

None yet.

### Blockers/Concerns

- [Roadmap]: OPEN — v1 (isolation) vs v2 (enforcement) ordering. Committed isolation-first; design doc flags it as a genuine choice. Do not auto-decide.
- [Phase 3]: World-B bar ("gate physically prevents breach regardless of agent code") is the real "v2 done" and a hard dependency of v3 — verify before starting Phase 4.
- [Concept]: Manual weekend precision experiment (does roster-driven surfacing find high-signal content?) still owed, independent of the build.

## Deferred Items

Items acknowledged and carried forward from previous milestone close:

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| v3 roadmap | Re-map v3 (Generation) as its own release sequence, not one release | Pending | Init |

## Session Continuity

Last session: 2026-06-27 (init)
Stopped at: Initial planning artifacts created from ingest
Resume file: None
