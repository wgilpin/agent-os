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

## Strategy: workload-driven build-out

Beyond Phase 8, substrate work is driven by concrete agents: pick a candidate agent, build
only the features it forces, and repeat until a new agent needs **zero** new substrate (only
composition of existing primitives) — the point of **feature saturation**. The candidate
agents, the substrate primitives they each force, and the saturation tracker live in
[agent-primitive-matrix.md](agent-primitive-matrix.md). Phase 9 is the first output of this
loop (surfaced by the "buying agent" example).

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Walking Skeleton (v0)** - BEAM substrate runs one hand-written discovery agent end-to-end on a daily timer
- [x] **Phase 2: Isolation (v1)** - Containerise the child agent so it is safe against the live web and daily-usable
- [x] **Phase 3: Manifest Enforcement (v2)** - Deterministic gate enforces the manifest from outside the agent; world-B airtight
- [x] **Phase 4: Generation MVP (v3)** - OS synthesises novel agents from a stated purpose behind the proven gate
- [x] **Phase 5: Live Connectivity & Client (v4)** - Live model calls over the internet via the inference broker
- [x] **Phase 6: Phoenix/LiveView Control Plane (v5)** - User-facing dashboard for the generation cycle
- [x] **Phase 7: Hardening & Sandbox (v6)** - Production-grade container + socket sandboxing
- [ ] **Phase 8: Connector Ecosystem (v7)** - Pluggable connector registry + synchronous tools (web search)
- [ ] **Phase 9: Persistent State & Permissions (v8)** - Queryable durable store, split build-time/runtime consent, agent-invisible namespaces

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
- [x] 02-01: Containerise the child agent; provision into a sandbox across the port boundary
- [x] 02-02: Sanitize untrusted web input; safe against injected bookmark/tweet
- [x] 02-03: Clean cross-boundary failure semantics (Python crash/OOM → clean BEAM exit)

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
- [x] 03-01: Deterministic gate validates every action vs enumerated grants + constraints (manifest non-agent-readable) — spec 002
- [x] 03-02: Substrate provisions from the enforced manifest; manifest gains constraints sub-block — spec 002
- [x] (US2) Manifest invisible to the agent — boundary invariant — spec 003-manifest-invisibility (commit a78afe9)
- [x] 03-03: Credential proxy holds caps + injects at the chokepoint — spec 004-credential-proxy (commit 1a17e04)
- [x] 03-04: Spend {cap, window, on_breach} — meter at chokepoint, per-agent visibility, real kill-on-breach — spec 005-spend-metering (commit 32b2d81)
- [x] 03-04a: Dollar spend metering via an inference chokepoint — spend becomes real dollars (tokens × price), metered trustlessly at a substrate-side inference broker — spec 006-dollar-spend-metering (commit 93baa16)
- [x] 03-05: Event-trigger + approval-as-event-trigger + message-trigger — spec 007 (commit f114c6d)
- [x] 03-06: World-B verification — gate physically prevents breach regardless of agent code (last) — spec 008-world-b-verification (merged 2026-06-29)

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
**Plans**: 10 (re-mapped 2026-06-29 from the 6 stage-placeholders)

> **SCOPE NOTE (do not treat as one release):** v3 is itself an entire roadmap, and
> scope-gravity relocates here if unchecked. The 10 plans below are the dependency-ordered
> re-map called for by the design doc (agent-os-design.md:206); the original 6 were pipeline
> stages, not a decomposition. Two overloaded stages were split (old 04-02 → render + gen;
> old 04-06 → review-modes + deploy + auditor) and the three open v3 design questions are
> folded into the plans that own them. Sequencing rationale below the list.

Plans:

*Rail (generation-independent; built & proven on the EXISTING hand-written discovery agent — same "earn it on easy mode first" discipline as v2):*
- [x] 04-01: Deterministic capability render — manifest → faithful/total/danger-ranked normie-readable consent view; a mechanical lookup from capability-type to phrase, NEVER LLM-written, and unable to drift from the actual grants (permission-visibility axis; always on, no flag)
- [x] 04-02: Conformance auditor — post-deploy, reads run-traces, compares stated purpose vs observed behaviour, FLAG-ONLY (never blesses, never auto-gates deploy); provenance rendered in the inventory — REQ-check-conformance
- [x] 04-03: Review modes + deterministic envelope predicate — `--always-review` (v3-launch default) | `--review-if-risky` | `--dangerously-skip-review`; the envelope is a deterministic predicate over manifest fields (read-only / no-egress / spend-under-threshold), never an LLM judgement; all three modes sit ABOVE the gate and none is permission to cross it; deploy provenance (reviewed=human | skipped-in-envelope | dangerously-skipped) recorded (commit eb675cf) — **resolves OQ: envelope threshold + auditor-as-precondition for envelope-eligibility**

*Generation pipeline (the novel part; the OS authors an agent):*
- [x] 04-04: Stage 1 — elicit the spec; the orchestrator questions the user until the purpose is KISS-clear (the load-bearing human-in-the-loop step that the co-generation caveat depends on) — REQ-elicit-spec
- [x] 04-05: Stage 2 — write the manifest (the safety artifact, not the judge) from the elicited spec; reuses the 04-01 render for the consent view — REQ-gen-manifest
- [x] 04-06: Stage 3 — write the judge; eval-lite that certifies code-matches-manifest (NOT manifest-matches-intent) — **resolves OQ: judge co-generation (does the judge need an independent derivation path, or is stage-1 elicitation enough?)** — REQ-write-judge
- [x] 04-07: Stage 4 — write the novel agent body; synthesise NEW Python/PydanticAI code (not template, not composition) across the port boundary — REQ-write-novel-agent (merged 2026-07-01)
- [x] 04-08: Stage 5 — security-review agent; reads code+manifest+purpose, judges "written to satisfy purpose without breaching manifest" as a smoke detector, not the firewall — **resolves OQ: security-review ↔ conformance-auditor shared injection/evasion surface** — REQ-security-review

*Wire it shut:*
- [x] 04-09: Stage 6 — deploy-on-green; gate deploy on a pass from BOTH judge AND security-review, plugged into the 04-03 review-mode rail; re-verify the manifest-not-readable-by-agent invariant now holds for a MACHINE-WRITTEN manifest — REQ-deploy-on-green
- [x] 04-10: E2E MVP thread + world-B-on-generated — the worked example ("reply to recruiter emails") runs the full pipeline human-out-of-the-loop after the conversation, AND the spec-008 world-B suite is re-run against a *generated* agent (machine-written manifest + machine-written code) — the headline acceptance criterion: enforcement holds regardless of code the OS wrote itself

### Phase 5: Live Connectivity & Client (v4)
**Goal**: Transition from static stubs to live model calls over the internet.
**Depends on**: Phase 4
**Success Criteria** (what must be TRUE):
  1. The inference broker dynamically communicates with upstream endpoints (like OpenRouter) for all agent and generation calls.
  2. Model credentials are securely loaded at runtime without being exposed to sandboxed containers.
**Plans**: 3
- [x] 05-01: HTTP Client & OpenRouter Transport — Add client dependency and implement actual HTTP routing in InferenceBroker.
- [x] 05-02: Secure Secret Provisioning — Dynamically load model API keys via CredentialProxy from environment/vault.
- [x] 05-03: Token Pricing Sync — Define dynamic model price lookups matching OpenRouter specs for spend metering.

### Phase 6: Phoenix/LiveView Control Plane (v5)
**Goal**: Build a user-facing dashboard and interactive interface for controlling the generation cycle.
**Depends on**: Phase 5
**Success Criteria** (what must be TRUE):
  1. Users can interactively converse with the elicitation orchestrator through a web interface.
  2. A secure consent screen displays exact permission grants before code execution.
**Plans**: 3
- [x] 06-01: Interactive Elicitation UI — Conversational LiveView workspace for user specification elicitation.
- [x] 06-02: Consent Screen UI — LiveView render of the mechanical capability render for approval.
- [x] 06-03: Standing Inventory Dashboard — Renders active agent roster, spend status, and audit logs.

### Phase 7: Hardening & Sandbox (v6)
**Goal**: Elevate sandboxing security and communication interfaces to production standards.
**Depends on**: Phase 6
**Success Criteria** (what must be TRUE):
  1. Agent container execution drops privileges and isolates the host system.
  2. Unix socket communication is secured via runtime constraints.
**Plans**: 2
- [x] 07-01: Container Privilege Restriction — Restrict docker capabilities, implement read-only filesystems, and strict CPU/memory limits.
- [x] 07-02: Socket Security & Permissions — Restrict socket accessibility and sanitize mounted directories inside the container.

### Phase 8: Connector Ecosystem (v7)
**Goal**: Grow what agents can *do* by making connectors pluggable and extending the catalogue beyond the built-in four. A connector becomes a self-contained module (metadata + grant-scope + execute) discovered from a registry, so adding a capability means dropping in one module — not editing the gate, the effector, and the credential loader. Enforcement is unchanged: the deterministic gate keeps validating every action against the manifest grants, and world-B stays green throughout. The first new capability *channel* is synchronous tools, landed via web search.
**Depends on**: Phase 4 (the gate, effector, credential proxy, and manifest projection that connectors plug into)
**Success Criteria** (what must be TRUE):
  1. Adding a connector is dropping ONE self-contained module into `lib/agent_os/connector/` — auto-discovered via the behaviour, with no edit to a central registry list, `Gate`, `Effector`, `CredentialSource`, `Manifest.Projection`, or `CapabilityRender`.
  2. The existing four connectors (`kv_append`, `external_send`, `gmail_read`, `gmail_draft`) run on the pluggable path with the world-B suite unchanged and green.
  3. Credential injection is generic: a connector declaring a credential gets it resolved (declared id → env var) and injected at the effector chokepoint post-approval (the `external_send` special-case is gone).
  4. A connector that raises or hangs during execution is contained — it fails closed as `{:error, …}`, is logged loudly, and never crashes the run worker or the substrate.
  5. web_search executes synchronously mid-reasoning, is gated by the manifest grant (no grant → no call), and its per-query cost meters against the spend cap.
**Plans**: 3
**Spec prompts**: drafted `/speckit-specify` prompts for the two outstanding plans (08-02, 08-03) in [phase-08-spec-prompts.md](phase-08-spec-prompts.md).

Plans:
- [x] 08-01 (Spec A): Pluggable connector registry — `AgentOS.Connector` becomes a behaviour; the registry is **auto-discovered** (modules implementing the behaviour under `lib/agent_os/connector/`), so there is no central list to edit; `registry/0` assembles the metadata map so `Gate` is untouched; effector dispatch + credential resolution become generic (credential by declared id → env var). Each `execute/2` runs **fault-contained** (timeboxed + rescue-wrapped → fail-closed `{:error}`, never crashes the run). Proven by **migrating the existing four connectors** with world-B green — no new connector added. Deliberately does NOT add a tool-channel callback (08-02), and does NOT change connectors from writing state to returning effects — that contract isolation (T1) is deferred to 08-03 since all v7 connectors are first-party.
- [x] 08-02 (Spec B): Synchronous tools + web_search — add a mid-inference tool-use channel over the inference broker (agent pauses reasoning → substrate runs the query → results injected into context in the same pass); land `web_search` as the first tool connector (metered per-query, credential-injected via `:search_api_key`), reusing the 08-01 registry for grant/scope. Depends on 08-01. NOTE: this same channel is the right home for an agent-initiated `kv_read` *tool* (selective/synchronous read driven by reasoning), as opposed to the ambient state push in the input payload — reads stay mounts, not grants, unless an agent genuinely needs to pull a key mid-reasoning. Deferred until a concrete agent requires it; do not build speculatively.
- [x] 08-03: Connector admission & compile-isolated plugins — the trust/loading boundary for connectors that are NOT first-party: contract isolation (T1 — connectors return effects, never touch substrate state directly), compile isolation (connectors as a separate Mix app / package so a bad connector can't break the core build), dynamic loading (install without rebuilding the core), and an admission gate (review + credential provisioning) since connector code runs inside the trusted substrate. The point where "no editing core code to add a connector" fully lands for third-party authors. Depends on 08-01.

**Sequencing rationale**: the rail (04-01…03) is generation-independent and built on the existing
discovery agent, delivering standing legibility/safety value (consent screen, auditor, review modes)
before generation exists and de-risking the machinery that doesn't depend on generation quality. The
generation pipeline (04-04…08) is the natural elicit→manifest→judge→agent→review thread, each stage
consuming the prior's artifact. 04-09 plugs generation into the rail; 04-10 is the integration + the
world-B-on-machine-written acceptance that is the whole point of v3. Phases 5–7 build post-MVP viability: connectivity first, followed by visual/control interfaces, ending with production-grade security sandboxing.

### Phase 9: Persistent State & Permissions (v8)
**Goal**: Replace the whole-file term-store with a queryable, crash-durable engine and refine the permission model. Today's `StateStore` persists one Erlang term-file rewritten in full on every write (O(total-size) per append, no query at all), and a single `requires_approval?` flag conflates two different human decisions — "may this agent be deployed holding this capability at all" (build-time) versus "must a human approve each individual call" (runtime). This phase: (1) splits consent into two orthogonal flags; (2) adds a queryable, append-cheap, durable store behind the existing single-writer `StateStore` contract, with policy-bound, agent-invisible namespaces; (3) retires the term-file backend by consolidating small state onto the new engine. The single-writer GenServer contract (invariant IX) and world-B stay unchanged throughout.
**Depends on**: Phase 8 (the auto-discovered connector registry — `store_find`/`store_append` land on the pluggable path)
**Surfaced by**: the "buying agent" example — a monitor that accumulates a long, queryable history of what it has seen/shown and remembers user feedback. An example workload that exposed these substrate gaps, not a committed product.
**Success Criteria** (what must be TRUE):
  1. Two independent flags exist — `requires_deploy_consent?` (build/deploy-time human approval that the capability may be granted at all; never parks a runtime action) and `requires_runtime_approval?` (per-call human sign-off at execution; reserved for dangerous actions). The gate parks an action IFF the runtime flag is set.
  2. A queryable store answers predicate FINDs (equality + `<`/`>`/`>=`, ordering, limit) without loading the whole store, appends without rewriting existing records, and survives a crash/restart with committed writes intact.
  3. Store namespaces are policy-bound and agent-invisible: no proposed action and nothing agent-observable contains a real namespace; the substrate resolves it from the matched grant. `Grant` gains a namespace binding; the connector `execute` path receives the grant-resolved namespace rather than reading a mount from the payload.
  4. The term-file persistence is gone; all mounts run on the new engine behind the unchanged single-writer contract; world-B stays green.
**Plans**: 3
**Spec prompts**: drafted `/speckit-specify` prompts for all three plans (and full context) in [phase-09-spec-prompts.md](phase-09-spec-prompts.md).

Plans:
- [x] 09-01: Split the connector approval flag into `requires_deploy_consent?` (build-time) + `requires_runtime_approval?` (per-call runtime); the gate parks only on the runtime flag; capability-render surfaces each distinctly. Clean cutover — no live state, so no migration: `requires_approval?` removed everywhere, and existing connectors mapped directly (only `external_send` → both true; `gmail_read` / `gmail_draft` / `kv_append` → both false).
- [x] 09-02: Queryable record store (**record/predicate mode only**) — embedded SQLite (`exqlite`) backend behind the `StateStore` single-writer contract; `store_find` (read, `:local`) + `store_append` (write, `:local`) connectors; append-cheap + predicate query + crash-durable; **policy-bound, agent-invisible namespaces** (namespace bound in the grant and resolved substrate-side; the agent never names or sees a store; where an agent uses multiple stores it addresses them by a manifest-assigned logical handle). Read/write asymmetry (agent queries history, only the substrate writes ledger/verdicts) falls out of granting `store_find` without `store_append`. De-hardcode `kv_append`'s `"roster_trust"`. Does NOT serve the map contract or touch existing mounts (that is 09-03). Depends on 09-01. **Engine choice open**: SQLite vs a zero-dependency append-log + ETS index — decide before implementing.
- [x] 09-03: Retire the term-file backend — first ADD a map/key-value mode (`:put`/`:delete_in`/`:append`/`snapshot`, per-key storage) to the 09-02 backend, then migrate the small-state mounts (`inference_broker`, `trigger_gateway`, `conformance_auditor`, `run_worker`, `inventory`, `provisioner`, `stage5_review`, `consent_live`) onto it, keep the single-writer GenServer contract, and delete term-file persistence entirely. No behaviour change visible to callers. Depends on 09-02.

> **BACKLOG (surfaced by the buying-agent example; do NOT build speculatively — same discipline as 08-02):** connector-catalogue and standing-objective primitives a real monitoring/purchasing agent would need — an **eBay read connector** (the first live-egress `execute/2`; OAuth app-token held and refreshed by the credential source, injected per-call), a **notify connector** (approved once at deploy via `requires_deploy_consent?`, `requires_runtime_approval?: false`, metered so the spend cap IS the rate limit — likely a scoped variant of `external_send`), a **durable "watch" objective** (a standing user-owned goal carrying dedupe/seen-set state that drives scheduled re-invocation), and **feedback conditioning** (substrate-written user verdicts read back via `store_find`; runtime-conditioning by default, regeneration through the consent envelope only for a genuine purpose shift). Build each when a concrete agent needs it. **Feasibility flag:** Facebook Marketplace has no API and blocks automation against the user's personal account — treat as out of scope; eBay (real Browse API + OAuth) is the clean first target.

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Walking Skeleton (v0) | 5/5 | Complete | 2026-06-28 |
| 2. Isolation (v1) | 3/3 | Complete | 2026-06-28 |
| 3. Manifest Enforcement (v2) | 8/8 | Complete — world-B proven | 2026-06-29 |
| 4. Generation MVP (v3) | 10/10 | Complete | 2026-07-01 |
| 5. Live Connectivity (v4) | 3/3 | Complete | 2026-07-01 |
| 6. LiveView Control Plane (v5) | 3/3 | Complete | 2026-07-01 |
| 7. Hardening & Sandbox (v6) | 2/2 | Complete | 2026-07-01 |
| 8. Connector Ecosystem (v7) | 0/3 | Not started | - |
| 9. Persistent State & Permissions (v8) | 0/3 | Not started | - |
