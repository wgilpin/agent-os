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
- [x] **Phase 8: Connector Ecosystem (v7)** - Pluggable connector registry + synchronous tools (web search)
- [x] **Phase 9: Persistent State & Permissions (v8)** - Queryable durable store, split build-time/runtime consent, agent-invisible namespaces
- [ ] **Phase 10: Priorities Coach (v9)** - First *live* read + notify + OAuth: a generated daily coaching agent that reads a doc, pings Google Chat, ingests the reply, and writes the doc back
- [ ] **Phase 11: Generated-Agent Runtime Isolation (v10)** - Every agent body — generated included — runs inside the container sandbox; runtime pluggable (runc → runsc/gVisor → Apple Containers endgame)
- [ ] **Phase 12: Single-User Ops Hardening (v11)** - The three ops gaps that matter for one person's always-on Mac: UI bound to localhost only, scheduled backups of `data/`, and an automatic container restart policy
- [ ] **Phase 13: Agent Runtime Kit (v12)** - Generated bodies stop hand-rolling transport: first-party `agent_os_runtime` (pydantic-ai-slim, pinned) speaks the broker UDS; tool stubs codegen'd from the connector registry per manifest grant; generation emits instructions + glue, not plumbing
- [ ] **Phase 14: Conversational Routing (v13)** - One chat surface over all agents: a trusted Elixir planner-router plans once from the user's utterance (roster = manifest purpose lines), executes deterministically via message-triggers with substrate-mediated artifact handoff; user↔agent only
- [ ] **Phase 15: User Profile Store (v14)** - Standing user-preference store: section-scoped `profile_read`/`profile_write` manifest grants over a substrate-owned namespace, writer provenance, LiveView editor
- [ ] **Phase 16: Operator Recall (v15)** - Full-text search over run history and transcripts in the inventory dashboard (operator-facing only)
- [ ] **Phase 17: Channel Gateway (v16)** - Messaging channels become a pluggable class: `ChannelAdapter` behaviour extracted from the Discord path, Telegram as N=2, all surfaces routing into the Phase 14 conversation orchestrator

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

### Phase 10: Priorities Coach (v9)
**Goal**: Deliver the **Priorities Coach** as a real, generated, *live* agent (not a mock): a daily 0800 run reads the user's priorities doc, pings them on Discord asking whether yesterday's stated intentions actually happened, coaches if appropriate, and writes the doc back — the user's Discord reply flowing back in to drive the update. All coaching/diff logic is machine-written agent body (Constitution IX); this phase builds only the substrate grants the manifest projection would need and can't yet issue. It is the widest gap-opener on the matrix: it lights four open columns (`Rd`, live `Mut`, `OAuth`, `Notif`) and is the first *live* exercise of `Evt` from a real external channel. **Part build (new primitives/connectors), part complete-not-mock:** no connector `execute/2` has ever crossed the network boundary (all egress is stubbed/sink-routed), the credential source is static-env-only (no OAuth), and the trigger gateway has message machinery but no real inbound surface. **Channel note:** Google Chat was ruled out — its webhooks/Chat-app API need a Google Workspace account and the operator is a personal `@gmail.com`; Discord incoming webhooks are a static per-channel URL that works on a personal account (outbound), though the inbound reply (10-03) needs a Discord bot/gateway rather than a plain inbound webhook.
**Depends on**: Phase 8 (pluggable connector registry + credential proxy + admission) and Phase 9 (queryable store — "since yesterday" is a live `store_find`).
**Surfaced by**: the Priorities-Coach candidate in [agent-primitive-matrix.md](agent-primitive-matrix.md). A validation scenario for the workload-driven loop, not a committed product.
**Success Criteria** (what must be TRUE):
  1. A generated agent makes a real outbound call — `chat_notify.execute/2` POSTs a live message to a real Google Chat space; nothing on this path is sink-routed or canned.
  2. A generated agent reads real external data bounded by a gate-enforced grant — a path-scoped grant (local file, Wave A) or an id-scoped Drive grant (Wave B).
  3. The user's Chat reply re-enters the substrate through an authenticated inbound endpoint and drives the same run's doc update (first live `Evt` from a real channel).
  4. The coach is machine-generated and auto-deployed through the unchanged pipeline, and world-B-on-generated stays green with the new grant shapes — no breach case dropped or relaxed.
  5. (Wave B) The credential source holds and refreshes an OAuth token, injecting the current access token per call without the agent ever observing it; Drive read + write-back work live.
**Plans**: 7 (Wave A: working live coach on a local file, no OAuth; Wave B: OAuth/Drive upgrade)
**Roadmap detail**: full breakdown, doc-location decision, and per-plan dependencies in [phase-10-priorities-coach-roadmap.md](phase-10-priorities-coach-roadmap.md). Per-plan `/speckit-specify` prompts drafted plan-by-plan when each is started (begin with 10-01).

Plans:
- [ ] 10-01: `discord_notify` connector — first connector `execute/2` that actually POSTs over the network (Discord incoming webhook). Static per-channel URL via the existing static credential source (no OAuth); metered, `requires_deploy_consent?: true`. Completes the live-egress path (`Notif` live). No deps.
- [ ] 10-02: Path-scoped file connectors `file_read` + `file_write` — first *live* `Rd` and `Mut` on a filesystem grant; forces a new **path-scoped grant shape** in the manifest/gate. No credential. No deps.
- [ ] 10-03: Inbound external message trigger — a Discord bot/gateway connection (persistent websocket or interactions endpoint) that receives the user's reply and maps it onto the waiting agent's message trigger (spec 007). First real external `Evt`; heavier than a plain inbound webhook. **Operator-identity pinning** (only the pinned operator id may fire a trigger) is written as the reference contract that the Phase 17 `ChannelAdapter` behaviour later extracts, not a Discord one-off. Depends on trigger gateway (present).
- [ ] 10-04: Generate the Priorities Coach end-to-end, live (Wave-A acceptance) — elicit → manifest (path read+write, `chat_notify`, chat-reply event, daily trigger, spend cap) → judge → novel body → security-review → deploy-on-green; re-prove world-B-on-generated with the new grant shapes; live smoke of the full 0800 loop. Depends on 10-01, 10-02, 10-03.
- [ ] 10-05: OAuth-with-refresh credential source (`OAuth` primitive) — extend `CredentialSource` (static-env only today) to hold a refresh token, rotate the access token, and inject the current one per call behind the credential-proxy boundary. Provisioned at admission (08-03). No deps (Wave B only).
- [ ] 10-06: `drive_read` + `drive_write` connectors — live read + write-back of a Google Doc over the 10-01 egress path using 10-05's OAuth credential; id-scoped grant. Depends on 10-01, 10-05.
- [ ] 10-07: Regenerate the coach against Drive (Wave-B acceptance) — re-run 10-04 with the doc source switched to Drive; confirm OAuth injection, live read/write, world-B still green. Depends on 10-04, 10-06.

### Phase 11: Generated-Agent Runtime Isolation (v10)
**Goal**: Close the runtime-containment gap for generated agents. Today `run_worker` routes any agent whose name ≠ the config agent AROUND the `Sandbox` — generated bodies run as a bare `.venv/bin/python` child of the BEAM, at the operator's macOS user, with full filesystem, open network, and clipboard access. Per [threat-model-agent-isolation.md](../docs/threat-model-agent-isolation.md), the layers are a funnel (Stage-5 review → Gate → sandbox) and residual risk is the *product* of the misses — but for generated agents the sandbox layer is absent, so the funnel degenerates to a single probabilistic layer (review) for exactly the code class that must be sized for the adversarial case. The operator's stated threat model is machine-authored code on a personal Mac with live bank/1Password/Google sessions: the concrete unmitigated paths are clipboard polling (1Password copies secrets there), reads of `~/.ssh`/`~/.aws`/`.env`/browser storage, and unrestricted outbound exfiltration. This phase routes ALL agent execution through the container sandbox, then hardens the wall in depth-ordered steps.
**Depends on**: Phase 7 (the hardened `Sandbox` argv builder + socket sandboxing that generated agents will now also run behind)
**Surfaced by**: review of the `run_worker` dispatch during 043 — the `agent_cmd: python_bin()` bypass at the generated-agent branch.
**Success Criteria** (what must be TRUE):
  1. No agent body executes outside the container sandbox: the direct-python dispatch branch in `run_worker` is gone; config and generated agents share the `Sandbox.build_argv` path (network=none, read-only root, cap-drop ALL, non-root, memory/pids limits), differing only in image and mounts.
  2. A generated agent's code is mounted read-only; its only writable surfaces are the scratch tmpfs and the inference UDS — proven by a world-B-style containment probe (attempt host-file read, outbound socket, write outside scratch → all fail, loudly logged).
  3. The container runtime is a config knob (`runc` | `runsc`), defaulting to runsc where available and falling back LOUDLY (Constitution VI) — never silently — where not.
  4. Docker Desktop file sharing is trimmed to the minimum host paths the substrate needs (the inference UDS dir and agent code mounts) — recorded as an operator checklist item in the threat-model doc, since root-in-VM reaches anything virtiofs-shared.
  5. (Endgame, own spec) An Apple Containers backend runs each agent in its own hardware VM natively on macOS — no Docker Desktop dependency — with the broker channel migrated from the UDS bind-mount to vsock (virtiofs cannot carry unix sockets; this is the backend's core design problem).
**Plans**: 4 (+ ops item)

Plans:
- [x] 11-01: Generated agents into the container sandbox (spec 044) — build a generated-agent runtime image (venv deps baked in, replacing the host `.venv/bin/python` resolution), mount `agents/<name>/` read-only, delete the `run_worker` bypass branch; containment probe added to the suite. No deps.
- [ ] 11-02 (ops, zero code): trim Docker Desktop → Resources → File Sharing from `/Users` down to the specific paths agent_os mounts; document in the threat-model note as a standing operator invariant. No deps.
- [ ] 11-03: Pluggable runtime knob — `Sandbox.build_argv` gains a configurable `--runtime`; default runsc (gVisor) where installed, loud fallback to runc; cuts the runc-escape → VM-root → shared-mount chain. Depends on 11-01.
- [ ] 11-04: Apple Containers backend — per-agent lightweight hardware VMs via Apple's `container` tool (native macOS, no Docker Desktop); requires a second argv builder (its CLI is not docker-flag-compatible) and the UDS→vsock migration of the broker channel. Spin-up target: sub-second cold; if per-run latency matters, a warm pool (pre-started sandboxes blocked on stdin-read — fits `PortRunner`'s one-JSON-line feed) is the lever, and it favours cheap-idle runtimes. Depends on 11-01; independent of 11-03.

> **Decision record (2026-07-10):** gVisor over Kata/Firecracker for the container-side hardening — comparable isolation for this workload shape (short-lived untrusted Python, syscall-light), ~tens-of-ms overhead vs hundreds, and critically it passes the host inference-UDS bind-mount through, which real VMs cannot (virtiofs drops sockets); a VM backend therefore requires the vsock rework and is sequenced as the 11-04 endgame rather than the default path. On macOS dev, Docker Desktop's Linux VM already provides a hardware wall between sandboxed agents and the host session — the acute gap is agents running outside any sandbox (11-01), not runc vs runsc (11-03).

### Phase 12: Single-User Ops Hardening (v11)
**Goal**: Close the small set of *operational* gaps that actually matter for the stated deployment model — a single user's always-on Mac (see README "Deployment model"; cloud-grade auth/TLS/multi-tenancy are out of scope by design). With the substrate containerized (spec 045), the app's remaining production distance is three plumbing items, not architecture.
**Depends on**: Spec 045 (containerized substrate is the thing being bound, backed up, and restarted)
**Success Criteria** (what must be TRUE):
  1. The web UI (including the consent screen) is reachable ONLY from the Mac itself: compose publishes `127.0.0.1:4000:4000`, not `4000:4000` — a device on the same LAN gets connection-refused.
  2. `data/` (state stores, run log, transcripts) is backed up on a schedule with retention, and a restore has been exercised once (a backup that has never been restored is a hope, not a backup).
  3. The substrate container comes back by itself: `restart: unless-stopped` (or equivalent) on the `substrate` service, verified by killing the container and observing recovery — including the broker re-binding its socket on the shared volume and triggers re-arming.
**Plans**: 3

Plans:
- [ ] 12-01: Localhost-only UI — change the compose port mapping to `127.0.0.1:4000:4000`; verify from a second device that :4000 is unreachable. No deps.
- [ ] 12-02: Scheduled `data/` backups — daily snapshot with 7-day/4-week retention to a location outside the repo (the stores are SQLite: copy via a consistent snapshot, not a live-file `cp`); document and exercise the restore path. No deps.
- [ ] 12-03: Restart policy — `restart: unless-stopped` on the substrate service; kill-test proves the broker socket, trigger re-arming, and UI all recover unattended. No deps.

### Phase 13: Agent Runtime Kit (v12)
**Goal**: Replace hand-rolled agent plumbing with a first-party runtime kit. Today every generated body re-invents ~40 lines of raw HTTP-over-UDS socket code and makes a single inference call (see any `agents/*/main.py`); "complex" agents (multi-step tool loops, retries, structured outputs, message history) have no home. This phase bakes an `agent_os_runtime` package into the generated-agent image (spec 044): a pydantic-ai `Model` that speaks the broker UDS, tool stubs **codegen'd from the connector registry for exactly the connectors the manifest grants**, and a blessed-subset import surface that becomes the Stage-4 generation cheat sheet. Generated bodies collapse to `Agent(instructions, tools, output_type)` — a smaller, uniform surface for the judge and security-review. The trust boundary does not move: in-body typing is DX and early failure; the gate remains the only enforcement, and the sandbox (network=none, UDS-only) physically kills the framework's native tools/MCP/direct-provider paths.
**Depends on**: Phase 8 (connector registry supplies the tool vocabulary), spec 044 (the image the kit bakes into). May run AHEAD of Phase 10: it changes what Stage 4 emits, and generating the Priorities Coach on the kit avoids regenerating it later.
**Success Criteria** (what must be TRUE):
  1. A generated body contains zero transport code: it imports only `agent_os_runtime` (which re-exports the blessed pydantic-ai subset) and runs against the broker UDS via the kit's Model.
  2. The tool stubs available inside a body are exactly the manifest-granted connectors, rendered mechanically from the same registry metadata the gate validates against — one source of truth, no drift.
  3. The framework is pinned exact (`pydantic-ai-slim[openai]==2.5.0`); a version bump is a deliberate event: the bake-off regression harness (`.planning/bakeoff-agent-framework/`) re-runs green and a golden agent regenerates through the full pipeline before the pin moves.
  4. Offline-total holds in the real image: a `--network=none` container run of a kit-based agent completes the golden tool task with zero egress attempts and no lazy asset downloads.
  5. The kit's invocation contract is session-shaped from day one: message history in, history delta out (persisted substrate-side), so chat-turn agents (Phase 14) require no body changes.
  6. World-B-on-generated stays green for kit-based bodies; spend reconciles call-for-call (every framework retry is a visible, metered broker request, bounded by explicit config).
**Plans**: 3
**Spec prompts**: 13-01 drafted in [phase-13-spec-prompts.md](phase-13-spec-prompts.md); 13-02/13-03 drafted plan-by-plan when started.
- [ ] 13-01: `agent_os_runtime` package + SubstrateModel — pydantic-ai `OpenAIChatModel` over `httpx.AsyncHTTPTransport(uds=…)` (first-class, proven in the bake-off), pinned deps baked into the generated-agent image; history-in/history-delta-out contract; in-image `--network=none` offline validation.
- [ ] 13-02: Connector tool-schema + per-grant stub codegen — connector behaviour gains a tool schema; provisioning renders typed pydantic-ai tool stubs for exactly the granted connectors, each a thin POST to `/v1/tool_calls`.
- [ ] 13-03: Stage-4 generation contract on the kit — blessed-subset cheat sheet into the generation prompt; judge + security-review updated for the smaller declarative surface; re-prove world-B-on-generated with a kit-based body.

> **Decision record (2026-07-12):** pydantic-ai-slim (v2 line, `[openai]` extra, pinned `==2.5.0`) backs the kit, chosen by empirical bake-off against a ~200-line no-framework baseline (scorecard + re-runnable harness: [bakeoff-agent-framework/](bakeoff-agent-framework/)). Both candidates passed every gating criterion — first-class UDS transport, offline-total under an AF_UNIX-only jail, zero uncommanded calls, bounded configurable retries; pydantic-ai costs 0.22s import / 30 pkgs / 45MB vs 0.03s / 5 pkgs / 8.3MB, immaterial in a container, and wins on declarative (machine-reviewable) bodies and generation familiarity. The no-framework loop is the kept **exit ramp**: because bodies import only the kit, swapping frameworks later is a kit release, not a generation-contract change. Version-churn risk is handled by the exact pin + regression harness, not by trusting the model's training data: the blessed API subset travels in the Stage-4 prompt. Incidental finding: macOS caps AF_UNIX `sun_path` at ~104 chars — keep `INFERENCE_SOCKET` paths short.

### Phase 14: Conversational Routing (v13)
**Goal**: One chat surface over all deployed agents. A **dispatcher, not a mediator**: a trusted Elixir planner-router receives the user's message plus a substrate-rendered roster (each agent's manifest purpose line + a small dataflow signature), makes ONE broker inference call emitting a typed plan (single target, or an ordered pipeline), and then the substrate executes it deterministically — each step an ordinary message-trigger invocation gated by that agent's own manifest, step outputs handed off as substrate-held artifacts. Control flow derives ONLY from the user's utterance; agent outputs flow through as data, never as control (the CaMeL pattern — the gate/manifest/store already are the capability interpreter). The rendered plan is the consent surface. The elicitation orchestrator becomes just another routable target ("no agent does this — want me to build one?").
**Depends on**: Phase 10 (first live conversational agent), Phase 13 (session-shaped invocation contract). Workload-gated per the build-out strategy: do not start before ≥2 message-triggered agents exist — routing with N=1 is an if-statement.
**Success Criteria** (what must be TRUE):
  1. The planner is unpoisonable by construction: its context is only the system concept + the substrate-rendered roster — never agent code, tool schemas, store contents, or any agent output. Roster lines are mechanical renders of the manifest (an agent NEVER authors its own routing description).
  2. Explicit `@agent-name` addressing bypasses the LLM router deterministically; unaddressed messages get one routing/planning call; open threads have sticky affinity (no re-route per message).
  3. A multi-step request ("read X, write a paper, add a todo") executes as a typed plan fixed BEFORE any untrusted data is read; injection in step data can corrupt step *content* but cannot add a step, change a recipient, or invoke another agent.
  4. Agents never talk to each other through the router; no merged transcript exists — the orchestrator holds per-agent threads, replies return verbatim and tagged. (Agent↔agent composition, if ever needed, is a future explicit manifested grant — `ask_agent` — not router plumbing.)
  5. Plans needing a data-dependent decision either carry a deterministic predicate over structured step output, or bounce back to the user in-thread — never an LLM re-plan from agent output.
  6. The planner has a frozen-roster golden-plan eval suite (utterance table → expected plans) running in CI.
**Plans**: 4 (sketch — refine at spec time)
- [ ] 14-01: Roster render — manifest purpose line + dataflow signature (accepts-artifact / produces-artifact / side-effect-only, derived from grant shapes), substrate-rendered; capability-render discipline.
- [ ] 14-02: Planner — typed plan schema (validated like any proposed action; unknown agent → reject; low confidence → ask user / offer elicitation), one broker call, golden-plan eval suite.
- [ ] 14-03: Conversation orchestrator — per-agent threads, sticky affinity, plan execution over message-triggers, artifact handoff via the 09-02 store, rendered-plan consent step. **Surface-agnostic by construction**: threads are keyed substrate-side with a surface tag, so Phase 17 channel adapters drop in without orchestrator rework.
- [ ] 14-04: Chat surface (LiveView) — unified conversation UI; elicitation orchestrator as a routable target; replies tagged by agent. LiveView is **one channel among N**, not the conversation surface — it talks to the orchestrator through the same interface a Phase 17 adapter will.

### Phase 15: User Profile Store (v14)
**Goal**: Standing user preferences become a substrate primitive agents can consume — the personalization benefit of a Hermes-style `USER.md` without the self-modification risk. A substrate-owned `profile` namespace on the 09-02 store holds sectioned preferences (e.g. `schedule`, `priorities`, `tone`). Access is **section-scoped manifest grants** in both directions: `profile_read: [sections]` exposes only the named slice (namespace/section resolution stays substrate-side and agent-invisible per 09-02; whole-profile reads do not exist), and `profile_write: [sections]` is a real grant — gate-enforced, section-scoped, `requires_deploy_consent?: true` — with writer provenance (agent, run, timestamp) recorded on every entry, so cross-agent influence through the profile is bounded by the manifest and legible in the log rather than forbidden. The operator edits the full profile in LiveView; dispatcher-mediated writes ("remember I prefer…" → substrate writes after in-thread confirm) arrive free with Phase 14. Nearly pure composition of existing primitives — a saturation-strategy win.
**Depends on**: Phase 9 (store + agent-invisible namespaces). **Sanctioned to run ahead of Phase 10**: the Priorities Coach is the first consumer — generating it with profile grants beats regenerating later (same logic that moved Phase 13 ahead).
**Surfaced by**: the Hermes Agent comparison (2026-07-21) — user-profile memory as a mounted store, not an agent-written file.
**Success Criteria** (what must be TRUE):
  1. A `profile_read` grant names sections; the agent observes only those sections; the capability render shows the user exactly which slice of their profile each agent sees.
  2. A `profile_write` grant names sections; a write outside the granted sections is physically blocked (world-B style — gate/store binding, not agent cooperation); every agent write carries provenance and is visibly attributed in the operator view.
  3. The operator can view and edit the full profile in LiveView, including deleting agent-written entries.
  4. A generated agent (the coach) can carry profile grants through the unchanged pipeline with world-B green.
**Plans**: 2
- [ ] 15-01: `profile` namespace + section-scoped `profile_read`/`profile_write` connectors on the store engine — grant-bound section resolution, write provenance, capability-render phrases, world-B cases for out-of-section read/write.
- [ ] 15-02: LiveView profile editor — full-profile view/edit, agent-written entries attributed, wired into the inventory dashboard.

### Phase 16: Operator Recall (v15)
**Goal**: Full-text search over everything the substrate already records — run log, action transcripts, elicitation transcripts — surfaced as a search box on the inventory dashboard. Pure legibility (the product): "what did any agent ever do mentioning X?" answered in one query. FTS5 virtual table over the existing 09-02 SQLite engine; no new state, no trust-boundary impact. **Operator-facing only**: an agent-facing `history_find` grant is explicitly NOT built — past sanitized-but-untrusted content re-entering a future agent's context is an injection-replay channel; it goes to the backlog with that flag and waits for an agent that genuinely forces it (dedupe needs are already served by scoped `store_find` on the agent's own namespace).
**Depends on**: 09-02 (SQLite engine). No phase depends on it; slots anywhere.
**Surfaced by**: the Hermes Agent comparison (2026-07-21) — FTS over history, kept on the operator side of the boundary.
**Success Criteria** (what must be TRUE):
  1. One search box on the inventory dashboard answers free-text queries across run log, action transcripts, and elicitation transcripts, with results linking to the full record.
  2. Indexing is incremental — appending a record does not rebuild the index, and search stays responsive at years of single-user history.
  3. Nothing agent-observable changes: no new grant, no new connector, world-B suite untouched.
**Plans**: 2
- [ ] 16-01: FTS5 index over run log + transcripts on the existing engine, populated incrementally behind the single-writer contract.
- [ ] 16-02: Search UI on the inventory dashboard — query, ranked results, deep-link to the underlying record.

### Phase 17: Channel Gateway (v16)
**Goal**: Messaging channels become a pluggable class, the way 08-01 made connectors one. Extract a `ChannelAdapter` behaviour from the 10-03 Discord path — inbound: authenticated message → message-trigger with **operator-identity pinning in the behaviour contract** (only the pinned operator id may fire a trigger, per-adapter implementations prove it, not re-invent it); outbound: reply delivery tagged per-surface — and prove the abstraction at N=2 with Telegram (clean bot API, no business-account hurdles; WhatsApp/Signal noted and skipped; iMessage tempting for a Mac-resident OS but rides fragile AppleScript — noted, not built). All channels route into the Phase 14 conversation orchestrator; cross-surface session continuation (start on the phone, pick up in LiveView) falls out of substrate-held threads with a surface tag. If the operator never wants a second messenger, this phase shrinks to the behaviour extraction alone.
**Depends on**: 10-03 (first real channel), Phase 14 (the surface-agnostic orchestrator channels plug into). Workload-gated with Phase 14.
**Surfaced by**: the Hermes Agent comparison (2026-07-21) — the symmetric multi-platform gateway, rebuilt as substrate-mediated trigger plumbing.
**Success Criteria** (what must be TRUE):
  1. Adding a channel is dropping ONE `ChannelAdapter` module — no edits to the trigger gateway, orchestrator, or any agent; the Discord path runs on the extracted behaviour with 10-04's live loop still green.
  2. A message from a non-pinned identity on any channel is rejected at the adapter with a loud log — enforced by the behaviour contract, verified per adapter.
  3. A conversation started on one surface continues on another: same thread, same sticky agent affinity, replies delivered to the surface the last message arrived on.
  4. Telegram works end-to-end as the N=2 proof: inbound to the dispatcher, reply back, operator-pinned.
**Plans**: 3
- [ ] 17-01: `ChannelAdapter` behaviour + Discord migration — extract from 10-03, operator-pinning and reply-delivery in the contract, trigger-gateway wiring generic.
- [ ] 17-02: Telegram adapter — bot API, long-poll or webhook, operator-pinned; the N=2 proof.
- [ ] 17-03: Cross-surface continuation — surface tag on substrate-held threads, reply routing to last-active surface, LiveView chat running through the same adapter interface.

> **Decision record (2026-07-12):** dispatcher topology over the standard mediator/orchestrator-agent pattern. A front agent that reads every worker reply and synthesizes answers is an LLM in a privileged position (no manifest describes it), a cross-agent injection channel (worker output steers the next invocation), and a legibility break (user sees paraphrase, log records actions). The dispatcher keeps the trusted layer deterministic: plan once from trusted input, execute mechanically, return replies verbatim. Accepted cost: no automatic cross-agent synthesis — the user reads N tagged replies, which for a single-operator system whose product is legibility is the right trade.

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15 → 16 → 17, with sanctioned deviations: 11-01/11-02 may run ahead of Phase 10 (active security gap, no Phase-10 dependency); Phase 12's plans are small, independent, and may slot in anytime after 045; **Phase 13 should run ahead of Phase 10** (it changes what Stage 4 emits — generate the coach on the kit rather than regenerate it after); **Phase 15 may run ahead of Phase 10** (small, composition-only, and the coach is its first consumer); Phase 16 slots anywhere after 09-02. Phase 14 is workload-gated (not before two message-triggered agents exist) and Phase 17 is gated with it.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Walking Skeleton (v0) | 5/5 | Complete | 2026-06-28 |
| 2. Isolation (v1) | 3/3 | Complete | 2026-06-28 |
| 3. Manifest Enforcement (v2) | 8/8 | Complete — world-B proven | 2026-06-29 |
| 4. Generation MVP (v3) | 10/10 | Complete | 2026-07-01 |
| 5. Live Connectivity (v4) | 3/3 | Complete | 2026-07-01 |
| 6. LiveView Control Plane (v5) | 3/3 | Complete | 2026-07-01 |
| 7. Hardening & Sandbox (v6) | 2/2 | Complete | 2026-07-01 |
| 8. Connector Ecosystem (v7) | 3/3 | Complete | 2026-07-02 |
| 9. Persistent State & Permissions (v8) | 3/3 | Complete | 2026-07-02 |
| 10. Priorities Coach (v9) | 0/7 | Planned — see [phase-10-priorities-coach-roadmap.md](phase-10-priorities-coach-roadmap.md) | — |
| 11. Generated-Agent Runtime Isolation (v10) | 1/4 | 11-01 done (spec 044); 11-02/03/04 open | 2026-07-11 |
| 12. Single-User Ops Hardening (v11) | 0/3 | Planned (follow-on to spec 045) | — |
| 13. Agent Runtime Kit (v12) | 0/3 | Planned — framework chosen by bake-off 2026-07-12; runs ahead of Phase 10 | — |
| 14. Conversational Routing (v13) | 0/4 | Deferred — workload-gated (needs ≥2 conversational agents) | — |
| 15. User Profile Store (v14) | 0/2 | Planned — may run ahead of Phase 10 (coach is first consumer) | — |
| 16. Operator Recall (v15) | 0/2 | Planned — slots anywhere after 09-02 | — |
| 17. Channel Gateway (v16) | 0/3 | Deferred — workload-gated with Phase 14 | — |
