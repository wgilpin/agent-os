# Agent OS

## What This Is

An operating system for agents: a deterministic BEAM/OTP control plane (the kernel)
that declares, enforces, observes, and supervises invocation-scoped agent processes.
The defining thesis is that the OS builds its own agents from a stated purpose. The
discovery agent — surfacing high-signal AI/ML content from a people-roster — is the
first real workload and proof case, not the product. The product is the OS.

## Core Value

The control plane is the product: everything an agent is and does is declared,
enforced, observable, and killable — never "ask the agent." If only one principle
survives, legibility does (the system always presents a standing inventory of what
exists and what it did).

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

(None yet — ship to validate)

### Active

<!-- Current scope. Building toward these. See REQUIREMENTS.md for full IDs/acceptance. -->

- [ ] v0 (R1) — Walking skeleton: one supervisor, one GenServer (roster/trust,
  single-writer), one timer (daily 07:00), one port → hand-written Python discovery
  agent, hand-written manifest, spend cap as a number, restart-once-and-alert.
- [ ] v1 (R2) — Isolation: containerise the child agent(s); safe to leave running
  against the live web (discovery agent reads untrusted X input); usable daily.
- [ ] v2 (R3) — Manifest enforcement: deterministic gate reads and enforces the
  manifest from outside the agent; manifest not agent-readable; boundary-contract
  fields (recipient scoping, on_breach, approval-as-event); credential proxy; spend
  metering + real kill-on-breach.
- [ ] v3 (R4) — Generation MVP: six-stage pipeline (elicit spec → write manifest →
  write judge → write agent → security-review → deploy-on-green); novel synthesis;
  security-review (pre-deploy) and conformance-auditor (post-deploy) are distinct.

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- Generation before enforcement — HARD ordering constraint: enforcement (v2) MUST
  precede generation (v3). Enforcement earns trust on easy mode (human authors)
  before generation makes it load-bearing.
- Long-lived / always-on agent processes — agents are invocation-scoped pure
  functions that run once and die; "looping" is a trigger re-invoking them.
- LLM on the safety-critical path — the deterministic gate is the only safety
  boundary; LLM review layers (security-review, conformance-auditor) are smoke
  detectors, never sprinklers, and can never grant a pass that crosses the gate.
- Auditor verdict auto-gating deployment — the conformance auditor can raise a
  flag, never grant a pass; auto-gating would make the system feel safer while
  being no safer.
- Templated / composed agents in v3 — v3 synthesises NOVEL code, not a
  parameterised template or a composition of pre-vetted components (both presuppose
  a coder upstream and fail the non-coder promise).

## Context

- **OS analogy (load-bearing):** kernel = substrate; process = invocation-scoped
  agent; manifest = executable header / syscall table; deterministic gate = syscall
  boundary (user→kernel ring); time/event/message triggers = cron / hardware
  interrupt / IPC; connector+mount grant = seL4 capability; supervisor = OTP
  supervisor; spend-cap kill = watchdog / OOM killer; security-review = code-review
  CI gate (pre-deploy); conformance-auditor = linter / runtime assertion (post-deploy).
- **Why build it (the nanoclaw contrast):** the "claw" class of personal-agent
  tools trades legibility for a small codebase — customization is code modification,
  state is reconstructable but never presented, and the only audit window routes
  through the same non-deterministic agent you are auditing (circular). Agent OS
  makes the opposite bet.
- **Validation owed (independent of the build):** a manual weekend precision
  experiment validating the discovery CONCEPT (does roster-driven surfacing find
  high-signal content) remains non-optional and is separate from the v0 skeleton test.
- **v0 skeleton test:** the weekend question is "does the one-supervisor /
  one-store / one-port skeleton feel right, or does it fight me?" — a structural
  milestone, explicitly not an MVP.

## Constraints

- **Tech stack**: BEAM/OTP (Elixir) is the control plane — supervisors, schedulers,
  mailboxes, single-writer state-owners, port boundaries. PROPOSED, not locked.
- **Tech stack**: Agent workloads in Python/PydanticAI (Vertex/Anthropic) execute
  across a port/HTTP boundary. A Python crash/OOM must surface to its BEAM
  supervisor as a clean process exit so let-it-crash works. PROPOSED, not locked.
- **Tech stack**: Gleam considered and deferred (not rejected) — revisit when
  building the gate.
- **Security**: No component both runs an LLM and holds a credential that can mutate
  external state. Privileged action is deterministic, on the agent's behalf, after a
  gate check (user-mode / kernel-mode ring split).
- **Security**: No ambient authority — an agent's manifest grants are its entire
  power; capability-based in the seL4 sense.
- **Security**: The manifest is privileged-read for the gate and NOT readable by the
  agent at all (stronger than read-only) — the agent is the untrusted party.
- **Security (v3 bar)**: World B — the gate must physically prevent any manifest
  breach regardless of agent code. This is the real bar for "v2 done" and a hard
  dependency of v3.
- **Concurrency**: Single owner per mutable store. Roster/trust KG → single-writer
  GenServer (no locks, no sharing). Append-only digest log → git-backed markdown.
- **Dependencies**: Enforcement (v2) precedes generation (v3) — cannot be reshuffled.

## Key Decisions

<!--
All 18 decisions below are PROPOSED / settled-by-exploration, sourced from
docs/agent-os-design.md. No ADRs exist in the ingest set, so NONE is locked or
non-overridable. To lock any one, promote it to a formal ADR — that is the path to
lock-level precedence.
-->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| LLM removed from the credential boundary (ring split) | Privileged action must be deterministic, never LLM-held | — Proposed |
| Agents are invocation-scoped pure functions (run once, die) | "Looping" is a trigger re-invoking; trigger is data, not behaviour | — Proposed |
| Substrate owns all persistent state and all scheduling | Deterministic, legible, killable; only the substrate persists | — Proposed |
| No ambient authority (manifest grants = entire power) | Capability-based security in the seL4 sense | — Proposed |
| Single writer per mutable store | Contended state owned by one writer, mutated via messages | — Proposed |
| Declarative manifest is single source of truth (7 core fields) | Humans read it, diffs track it; each field is an inventory column | — Proposed |
| Legibility is non-negotiable (the one principle with no flag) | Standing inventory always on; never "ask the agent" | — Proposed |
| Run-to-completion scheduling with kill-based preemption | Cannot interrupt-to-timeshare; must interrupt-to-kill on budget breach | — Proposed |
| Exactly three trigger types (time / event / message) | Approval modelled as event-trigger; keeps everything invocation-scoped | — Proposed |
| Deterministic gate is the only firewall | LLM review layers are smoke detectors, not sprinklers | — Proposed |
| Conformance auditor is flag-only (asymmetric authority) | Can raise a flag, never grant a pass; verdict never auto-gates deploy | — Proposed |
| Security-review distinct from conformance-auditor | Reviews CODE pre-deploy vs RUN-TRACES post-deploy; both LLMs, neither firewall | — Proposed |
| v3 synthesises a NOVEL agent (not template, not composition) | Both weaker readings presuppose a coder upstream | — Proposed |
| World B deterministic-gate floor required for v3 | Auto-deploy-on-green defensible only when gate physically prevents breach | — Proposed |
| Manifest not readable by the agent (stronger than read-only) | An agent that can read its allowlist can hug the boundary precisely | — Proposed |
| Review-mode and permission-visibility are orthogonal axes | Review mode never permits crossing the gate; visibility always on, no flag | — Proposed |
| Enforcement precedes generation (cannot be reshuffled) | Earns trust on easy mode before generation makes it load-bearing | — Proposed |
| BEAM/OTP (Elixir) now; Python/PydanticAI across port boundary | Most reps, OTP is what's needed; revisit Gleam when building the gate | — Proposed |
| MVP is v3, not v0 | v0 is a structural milestone; v3 is itself an entire roadmap | — Proposed |

## Open Questions (carried forward — do NOT auto-decide)

- **v1 / v2 ordering**: Committed order is isolation (v1) → enforcement (v2), per
  the PRD story map and plan.md. The design doc presents it as a GENUINE open choice
  with a risk-driven recommendation for isolation-first (the current discovery agent
  processes untrusted web input now; enforcement primarily protects against a future
  machine author). Committed order recorded; open-question preserved.
- **Manifest boundary-contract fork**: fat manifest (scoping/approval/breach
  in-manifest, true single source of truth) vs thin manifest + separate gate-policy
  file. Leaning fat.
- **Cross-boundary failure semantics**: Python crash → clean BEAM exit (ports /
  :erlexec / equivalent).
- **Auditor / agent shared attack surface**: two LLMs on the same adversarial channel.
- **Is the gate strong enough for world B?** Hard dependency of v3; the real bar for
  "v2 done."
- **Security-review ↔ conformance-auditor shared attack surface.**
- **Judge co-generation**: does the judge need an independent derivation path? A
  misread spec produces an agent AND a test-suite wrong in the same direction.
- **Envelope threshold + auditor-as-precondition** for envelope-eligibility. Leaning yes.
- **v3 internal roadmap**: unwritten by design; must be re-mapped as its own release
  sequence when next, not treated as one release.

---
*Last updated: 2026-06-27 after initial ingest-based project initialization*
