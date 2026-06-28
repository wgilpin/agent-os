# Roadmap: Agent OS

## Overview

Agent OS is built as a deliberate trust-earning sequence. First a walking skeleton
proves the BEAM substrate can run one hand-written agent end-to-end (does the shape
feel right?). Then the child agent is isolated so the discovery agent is safe to
leave running against the live web and becomes daily-usable. Then the deterministic
gate becomes a real enforcement boundary — the manifest enforced from outside the
agent, credential proxy, spend metering, real kill-on-breach — earning trust on easy
mode (human authors). Only then does generation arrive: the OS synthesises novel
agents from a stated purpose behind that same now-proven gate. The hard rule:
enforcement precedes generation, always.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Walking Skeleton (v0)** - BEAM substrate runs one hand-written discovery agent end-to-end on a daily timer
- [ ] **Phase 2: Isolation (v1)** - Containerise the child agent so it is safe against the live web and daily-usable
- [ ] **Phase 3: Manifest Enforcement (v2)** - Deterministic gate enforces the manifest from outside the agent; world-B airtight
- [ ] **Phase 4: Generation MVP (v3)** - OS synthesises novel agents from a stated purpose behind the proven gate

## Phase Details

### Phase 1: Walking Skeleton (v0)
**Goal**: The BEAM substrate runs one hand-written Python discovery agent end-to-end — declared by a hand-kept manifest, mounted to single-writer state, fired by a daily timer, with a legible run-log and restart-once-and-alert supervision. This is a structural milestone (does the one-supervisor / one-store / one-port skeleton feel right?), explicitly not an MVP.
**Depends on**: Nothing (first phase)
**Requirements**: REQ-write-manifest, REQ-state-purpose, REQ-grant-connectors-mounts, REQ-set-spend-cap, REQ-instantiate-from-declaration, REQ-mount-state, REQ-trigger-time, REQ-hand-input, REQ-reason-over-input, REQ-propose-enumerated-actions, REQ-validate-action-vs-grants, REQ-act-on-behalf, REQ-list-inventory, REQ-read-run-trace, REQ-restart-policy
**Success Criteria** (what must be TRUE):
  1. A hand-written markdown manifest (purpose as a one-line contract, connectors/mounts, spend cap as a number) describes the discovery agent, and a human keeps it in sync.
  2. At the daily 07:00 timer, the substrate fires one supervisor → one port → the human-written Python discovery agent, which reasons over input and proposes enumerated actions.
  3. Roster/trust state is mounted to a single-writer GenServer and the privileged action runs deterministically on the agent's behalf after a minimal output check.
  4. A standing inventory shows what exists and a legible run-log shows what it did — read without asking the agent.
  5. When the child fails, restart-once-and-alert fires.
**Plans**: 5 plans (4 waves)

Plans:
- [x] 01-01-PLAN.md — Scaffold single Mix app + single-writer RosterStore GenServer + manifest parser & 7-field manifest (wave 1)
- [x] 01-02-PLAN.md — Hard-wired provisioning + manifest-drift check + daily 07:00 self-rescheduling timer (wave 2)
- [x] 01-03-PLAN.md — Port boundary (stdin-guard wrapper + PortRunner) → human-written Python discovery agent (wave 2)
- [x] 01-04-PLAN.md — Deterministic minimal output check + act-on-behalf effector (ring split) (wave 3)
- [x] 01-05-PLAN.md — Legible run-log + standing inventory + end-to-end run pipeline + restart-once-and-alert (wave 4)

### Phase 2: Isolation (v1)
**Goal**: The child discovery agent runs sandboxed in a container, making it the first version safe to leave running against the live web (it reads untrusted X input now). The discovery agent becomes daily-runnable for the user. A child OOM/crash surfaces cleanly so let-it-crash works.
**Depends on**: Phase 1
**Requirements**: REQ-surface-child-crash
**Success Criteria** (what must be TRUE):
  1. The discovery agent is provisioned into a container and runs sandboxed.
  2. The agent is safe against an injected bookmark/tweet — it reasons over sanitized untrusted web input.
  3. A child OOM or crash surfaces to its BEAM supervisor as a clean process exit.
  4. The discovery agent is usable daily by the user without supervision.
**Plans**: TBD

Plans:
- [ ] 02-01: Containerise the child agent; provision into a sandbox across the port boundary
- [ ] 02-02: Sanitize untrusted web input; safe against injected bookmark/tweet
- [ ] 02-03: Clean cross-boundary failure semantics (Python crash/OOM → clean BEAM exit)

> **OPEN QUESTION (preserved, do not auto-decide):** v1 (isolation) vs v2
> (enforcement) ordering. Committed order is isolation-first (PRD story map + plan.md),
> recommended on a risk basis because the discovery agent processes untrusted web
> input NOW while enforcement primarily protects against a future machine author. The
> design doc flags this as a GENUINE choice — there is a real argument for proving the
> architecturally-central thing (enforcement) first. Order committed; choice open.

### Phase 3: Manifest Enforcement (v2)
**Goal**: The deterministic gate becomes a real safety boundary. The substrate provisions from the enforced manifest; the gate validates every action against the manifest's enumerated grants + constraints from OUTSIDE the agent; the manifest is not agent-readable; a credential proxy holds caps and injects at the chokepoint; spend is {cap, window, on_breach} with metering and a real kill-on-breach. The real bar is world B — the gate physically prevents any manifest breach regardless of agent code. This is what "v2 done" means and the hard dependency of v3. Enforcement must be earned here, on easy mode (human authors), BEFORE generation.
**Depends on**: Phase 2
**Requirements**: REQ-wire-credentials, REQ-trigger-event, REQ-trigger-message, REQ-inject-credential, REQ-meter-spend, REQ-see-spend, REQ-kill-on-breach
**Success Criteria** (what must be TRUE):
  1. The substrate provisions the agent from the enforced manifest, and the deterministic gate validates every proposed action against enumerated grants + constraints (recipient/method scoping lives in the manifest, not hidden in the gate).
  2. The manifest is privileged-read for the gate only and is NOT readable by the agent at all.
  3. The credential proxy holds capabilities and injects credentials at the deterministic chokepoint; no LLM-running component holds a mutating credential.
  4. Spend is {cap, window, on_breach}, metered at the chokepoint, per-agent visible, and a breach triggers a real kill.
  5. Event-triggers and message-triggers work (approval modelled as an event-trigger; you, via chat, are another process).
  6. World B holds: the gate physically prevents a manifest breach regardless of agent code.
**Plans**: TBD

Plans:
- [ ] 03-01: Deterministic gate validates every action vs enumerated grants + constraints (manifest non-agent-readable)
- [ ] 03-02: Substrate provisions from the enforced manifest; manifest gains constraints sub-block
- [ ] 03-03: Credential proxy holds caps + injects at the chokepoint
- [ ] 03-04: Spend {cap, window, on_breach} — meter at chokepoint, per-agent visibility, real kill-on-breach
- [ ] 03-05: Event-trigger + approval-as-event-trigger + message-trigger
- [ ] 03-06: World-B verification — gate physically prevents breach regardless of agent code

### Phase 4: Generation MVP (v3)
**Goal**: The OS becomes itself: a non-coder declares a purpose and the OS synthesises a NOVEL agent (new code, not template/compose) behind the deterministic gate proven in Phase 3. The six-stage pipeline runs human-out-of-the-loop after the conversation: elicit spec → write manifest → write judge → write novel agent → security-review → deploy-on-green. Security-review (reads code pre-deploy, gate-on-green) and the conformance-auditor (reads run-traces post-deploy, flag-only) are distinct components; neither is the firewall. Auto-deploy-on-green is sound ONLY in world B.
**Depends on**: Phase 3 (HARD: enforcement precedes generation — cannot be reshuffled)
**Requirements**: REQ-elicit-spec, REQ-gen-manifest, REQ-write-judge, REQ-write-novel-agent, REQ-security-review, REQ-deploy-on-green, REQ-check-conformance
**Success Criteria** (what must be TRUE):
  1. The OS questions the user until the purpose is KISS-clear, then emits a human-readable manifest — and that manifest, not the judge, is the safety artifact.
  2. The OS writes a co-generated judge (certifies code-matches-manifest, not manifest-matches-intent) and synthesises a novel Python/PydanticAI agent body across the port boundary.
  3. The security-review agent reads code+manifest+purpose and judges "written to satisfy purpose without breaching manifest" as a smoke detector, not the firewall.
  4. On pass from BOTH judge and security-review, the agent deploys with no further human input — and the gate still enforces the machine-written manifest at runtime even under --dangerously-skip-review.
  5. Review mode (--always-review default | --review-if-risky | --dangerously-skip-review) governs whether deploy blocks on a human; the envelope is a deterministic predicate over manifest fields; permission visibility is always shown at deploy in every mode.
  6. The conformance auditor compares stated purpose vs observed behaviour from real run-traces, flag-only — it can raise a flag, never grant a pass, and never auto-gates deployment; provenance (reviewed=human | skipped-in-envelope | dangerously-skipped) is recorded in the inventory.
**Plans**: TBD

> **SCOPE NOTE (do not treat as one release):** v3 is itself an entire roadmap. The
> six plans below are the pipeline stages, NOT a final decomposition. When v3 is next
> worked, re-map it as its own release sequence via a dedicated milestone/roadmap pass.

Plans:
- [ ] 04-01: Stage 1 — elicit the spec (question until KISS-clear)
- [ ] 04-02: Stage 2 — write the manifest (the safety artifact) + faithful/total/danger-ranked capability render
- [ ] 04-03: Stage 3 — write the judge (co-generation caveat: certifies code-matches-manifest)
- [ ] 04-04: Stage 4 — write the novel agent body (Python/PydanticAI across the port boundary)
- [ ] 04-05: Stage 5 — security-review (reads code+manifest+purpose; smoke detector, not firewall)
- [ ] 04-06: Stage 6 — deploy-on-green + review modes + envelope predicate; conformance auditor (flag-only, post-deploy)

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Walking Skeleton (v0) | 5/5 | Complete | 2026-06-28 |
| 2. Isolation (v1) | 0/3 | Not started | - |
| 3. Manifest Enforcement (v2) | 0/6 | Not started | - |
| 4. Generation MVP (v3) | 0/6 | Not started | - |
