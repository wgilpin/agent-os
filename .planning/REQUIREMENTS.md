# Requirements: Agent OS

**Defined:** 2026-06-27
**Core Value:** The control plane is the product — everything an agent is and does is declared, enforced, observable, and killable; never "ask the agent."

> Requirements extracted from `docs/agent_os.md` (PRD story map). Each requirement
> carries release-tagged acceptance ([R1]=v0, [R2]=v1, [R3]=v2, [R4]=v3) and the
> story-map node id. Several requirements span multiple releases; each is mapped in
> Traceability to the phase where it FIRST becomes a deliverable. Later-release
> acceptance is delivered by the corresponding later phase (noted per requirement).

## v1 Requirements

Requirements for the initial release sequence (v0 → v3). Each maps to roadmap phases.

### Declare an agent

- [ ] **REQ-write-manifest** (#2KPW): Hand-write a markdown manifest, human-kept-in-sync [R1]. Manifest gains boundary-contract fields — recipient scoping, on_breach, approval-as-event [R3].
- [ ] **REQ-state-purpose** (#FITq): Purpose stated as a one-line contract [R1]. Declare a purpose; OS emits the manifest [R4].
- [ ] **REQ-grant-connectors-mounts** (#kfHl): Connectors and mounts listed by hand [R1]. Manifest carries a normie-readable capability render that is faithful+total, deterministic, and danger-ranked [R4].
- [ ] **REQ-set-spend-cap** (#5X2o): Spend cap as a number, no on_breach yet [R1]. Spend becomes {cap, window, on_breach} [R3].

### Provision it from the declaration

- [ ] **REQ-instantiate-from-declaration** (#tsAh): Hard-wired config, not provisioned from manifest [R1]. Provision agent into a container [R2]. Substrate provisions from the enforced manifest [R3]. OS composes/selects template, validates generated manifest is well-formed and minimally-scoped [R4].
- [ ] **REQ-mount-state** (#zYXh): Roster/trust state mounted to single-writer GenServer [R1].
- [ ] **REQ-wire-credentials** (#CUeC): Credential proxy holds caps, injects at request time [R3].

### Trigger it into motion

- [ ] **REQ-trigger-time** (#uWCd): One timer — daily 07:00 emergence signal [R1].
- [ ] **REQ-trigger-event** (#KjA1): Event-trigger + approval-as-event-trigger [R3].
- [ ] **REQ-trigger-message** (#KEa1): Message-trigger — you, via chat, are another process [R3].

### Run it (LLM does the work)

- [ ] **REQ-hand-input** (#bvJu): One port → human-written Python discovery agent [R1]. Agent runs sandboxed; safe against injected bookmark/tweet [R2]. OS synthesises a NOVEL agent body [R4].
- [ ] **REQ-reason-over-input** (#lLQo): LLM reasons over input, unsanitized at v0 [R1]. Reasons over sanitized untrusted web input [R2].
- [ ] **REQ-propose-enumerated-actions** (#SlBh): Proposes enumerated actions [R1].

### Gate its outputs before effect

- [ ] **REQ-validate-action-vs-grants** (#1dB6): Minimal output check, not enforcement [R1]. Deterministic gate validates every action vs enumerated grants + constraints [R3]. Gate checks a machine-written manifest [R4]; holds against machine-written CODE — world B [R4]; manifest not agent-readable [R4]; --dangerously-skip-review skips deploy-review ONLY, the gate still enforces at runtime [R4].
- [ ] **REQ-inject-credential** (#lgL7): Credential proxy injects at the chokepoint [R3].
- [ ] **REQ-meter-spend** (#z0ey): Spend metered at the deterministic chokepoint [R3].
- [ ] **REQ-act-on-behalf** (#3BMV): Privileged action on agent's behalf, deterministic [R1].

### Observe what exists and what it did

- [ ] **REQ-list-inventory** (#KJpY): Standing inventory of what exists [R1]. Security-review verdict + judge result shown in inventory; permission summary always shown at deploy in every mode; inventory records provenance (reviewed=human | skipped-in-envelope | dangerously-skipped) [R4].
- [ ] **REQ-read-run-trace** (#Y8zJ): A legible run-log [R1].
- [ ] **REQ-see-spend** (#nTGk): Per-agent spend visible from the chokepoint [R3].
- [ ] **REQ-check-conformance** (#6BE0): Conformance auditor compares stated purpose vs observed behaviour, flag-only; flags drift to human; human stays on approve-path [R4].

### Supervise its lifecycle and failures

- [ ] **REQ-restart-policy** (#c93t): Restart-once-and-alert policy [R1].
- [ ] **REQ-kill-on-breach** (#hvGK): Spend-cap-on-breach becomes a real kill [R3].
- [ ] **REQ-surface-child-crash** (#qLnP): Child OOM/crash surfaces as clean BEAM exit [R2].

### Generate an agent from a stated purpose (v3)

- [ ] **REQ-elicit-spec** (#Krpq): Question the user until purpose is clear; minimise everything (KISS) — the real defence against spec-misread [R4].
- [ ] **REQ-gen-manifest** (#NXpM): Emit manifest from elicited spec; the human-readable manifest is THE safety artifact [R4].
- [ ] **REQ-write-judge** (#rhj7): Synthesise tests; LLM-judged, non-deterministic; certifies code-matches-manifest, not manifest-matches-intent [R4].
- [ ] **REQ-write-novel-agent** (#dQqr): Synthesise novel agent body (Python/PydanticAI across the port boundary) [R4].
- [ ] **REQ-security-review** (#0xZH): Reads code+manifest+purpose, judges "written to satisfy purpose without breaching manifest" — smoke detector, not firewall [R4].
- [ ] **REQ-deploy-on-green** (#7jkj): On pass from judge AND security review, deploy with no further human input — sound ONLY in world B. Review modes: --always-review (v3-launch default), --review-if-risky, --dangerously-skip-review. Envelope is a deterministic predicate over manifest fields [R4].

## v2 Requirements

Deferred beyond the current v0→v3 sequence. None at this time — the four releases
above constitute the committed scope. The v3 internal roadmap is unwritten by design
and will be re-mapped as its own release sequence when next worked.

## Out of Scope

| Feature | Reason |
|---------|--------|
| Generation before enforcement | Hard ordering constraint — enforcement (v2) must precede generation (v3) |
| Long-lived / always-on agents | Agents are invocation-scoped; "looping" is a trigger re-invoking |
| LLM on the safety-critical path | Deterministic gate is the only firewall; LLM layers are smoke detectors |
| Auditor verdict auto-gating deploy | Auditor is flag-only; auto-gating makes the system feel safer while no safer |
| Templated / composed v3 agents | v3 synthesises NOVEL code; weaker readings presuppose a coder upstream |
| Agent-readable manifest | Manifest is privileged-read for the gate only; the agent is the untrusted party |

## Traceability

Each requirement maps to the phase where it FIRST becomes a deliverable. Requirements
spanning releases are completed incrementally across later phases (see acceptance tags).

| Requirement | Phase | Status |
|-------------|-------|--------|
| REQ-write-manifest | Phase 1 | Pending |
| REQ-state-purpose | Phase 1 | Pending |
| REQ-grant-connectors-mounts | Phase 1 | Pending |
| REQ-set-spend-cap | Phase 1 | Pending |
| REQ-instantiate-from-declaration | Phase 1 | Pending |
| REQ-mount-state | Phase 1 | Pending |
| REQ-trigger-time | Phase 1 | Pending |
| REQ-hand-input | Phase 1 | Pending |
| REQ-reason-over-input | Phase 1 | Pending |
| REQ-propose-enumerated-actions | Phase 1 | Pending |
| REQ-validate-action-vs-grants | Phase 1 | Pending |
| REQ-act-on-behalf | Phase 1 | Pending |
| REQ-list-inventory | Phase 1 | Pending |
| REQ-read-run-trace | Phase 1 | Pending |
| REQ-restart-policy | Phase 1 | Pending |
| REQ-surface-child-crash | Phase 2 | Pending |
| REQ-wire-credentials | Phase 3 | Pending |
| REQ-trigger-event | Phase 3 | Pending |
| REQ-trigger-message | Phase 3 | Pending |
| REQ-inject-credential | Phase 3 | Pending |
| REQ-meter-spend | Phase 3 | Pending |
| REQ-see-spend | Phase 3 | Pending |
| REQ-kill-on-breach | Phase 3 | Pending |
| REQ-elicit-spec | Phase 4 | Pending |
| REQ-gen-manifest | Phase 4 | Pending |
| REQ-write-judge | Phase 4 | Pending |
| REQ-write-novel-agent | Phase 4 | Pending |
| REQ-security-review | Phase 4 | Pending |
| REQ-deploy-on-green | Phase 4 | Pending |
| REQ-check-conformance | Phase 4 | Pending |

**Coverage:**
- v1 requirements: 30 total
- Mapped to phases: 30
- Unmapped: 0 ✓

> Note: Phase 2 (Isolation) advances the [R2] acceptance of REQ-hand-input and
> REQ-reason-over-input and REQ-instantiate-from-declaration without owning those
> requirements outright — they are owned by Phase 1 (first deliverable) and
> Phase 3 (final enforcement). REQ-surface-child-crash is Phase 2's own first
> deliverable. This is incremental delivery across phases, not duplicate ownership.

---
*Requirements defined: 2026-06-27*
*Last updated: 2026-06-27 after initial definition*
