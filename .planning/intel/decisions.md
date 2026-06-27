# Decisions

Architectural decisions extracted from ingested planning docs.

Note: No ADRs were present in this ingest set. The decisions below were
extracted from `docs/agent-os-design.md` (classified DOC, high confidence),
which self-describes as "a structural plan, not a spec" that "captures the
decisions made during exploration." These are treated as **proposed /
settled-by-exploration**, NOT `locked` — the doc carries no Accepted status
and no ADR structure. Downstream consumers (roadmapper) should promote any
of these to a formal ADR if they need lock-level precedence.

---

## DEC-remove-llm-from-credential-boundary
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled principle)
- scope: trust-zone architecture / credential boundary
- decision: No component both runs an LLM and holds a credential that can
  mutate external state. Privileged action happens deterministically, on the
  agent's behalf, after a check (user-mode / kernel-mode ring split).

## DEC-invocation-scoped-agents
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled principle)
- scope: agent execution model
- decision: Agents are invocation-scoped pure functions — they run once and
  die. "Looping" is an invocation-scoped agent plus a trigger that re-invokes
  it; the trigger is data, not behaviour.

## DEC-substrate-owns-all-state
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled principle)
- scope: state ownership / scheduling
- decision: The substrate (kernel) owns all persistent state and all
  scheduling. Deterministic, legible, killable. The substrate is the only
  thing that persists.

## DEC-no-ambient-authority
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled principle)
- scope: security model
- decision: No ambient authority. An agent's manifest grants are its entire
  power; nothing is implicit. Capability-based security in the seL4 sense.

## DEC-single-writer-per-store
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled principle)
- scope: concurrency / state
- decision: Single owner per mutable store. Contended state is never shared;
  it is owned by one writer and mutated only through messages to that owner.
  The roster / trust-propagation KG is owned by a single-writer process
  (GenServer); the append-only digest log is git-backed markdown.

## DEC-declarative-manifest-single-source-of-truth
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled principle)
- scope: agent definition
- decision: Declarative manifests are the single source of truth — purpose,
  triggers, connectors, mounts, outputs, spend, supervision are declared in a
  manifest humans read and diffs track. Seven core fields, each rendering as
  an inventory column.

## DEC-legibility-non-negotiable
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled principle)
- scope: observability / consent
- decision: Legibility is non-negotiable and is the one principle with no
  flag. The system always presents a standing inventory of what exists and
  what it did. Never "ask the agent." Permission visibility is always on at
  deploy in every review mode.

## DEC-run-to-completion-with-kill-preemption
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled)
- scope: scheduling
- decision: Scheduling is run-to-completion with kill-based preemption. The
  substrate cannot interrupt-to-timeshare but must interrupt-to-kill when an
  agent exceeds its budget. Spend-cap-on-breach is the killer.

## DEC-trigger-taxonomy-three-types
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled, "complete")
- scope: trigger model
- decision: Exactly three trigger types — time (clock), event (world),
  message (another process, including the user). Approval is modelled as an
  event-trigger ("on approval-granted, fire executor"), keeping everything
  invocation-scoped.

## DEC-deterministic-gate-is-the-firewall
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled, load-bearing)
- scope: enforcement
- decision: The deterministic gate is the only safety boundary. It validates
  every action against the manifest's enumerated grants + constraints. LLM
  review layers (security-review agent, conformance auditor) are probabilistic
  "smoke detectors, not sprinklers" and are never the firewall.

## DEC-conformance-auditor-flag-only
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled)
- scope: post-deploy review
- decision: The conformance auditor audits behaviour from real run-traces, has
  asymmetric authority (can raise a flag, can never grant a pass), and asks a
  bounded question ("given the agent may do X,Y,Z, is what it did consistent
  with the purpose?"). Its verdict must never auto-gate deployment.

## DEC-security-review-distinct-from-auditor
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled)
- scope: pre-deploy review
- decision: The security-review agent and the conformance auditor are two
  distinct components. Security-review reads CODE pre-deploy (gate-on-green,
  sound only in world B); the auditor reads RUN-TRACES post-deploy (flag-only).
  Both are LLMs; neither is the firewall.

## DEC-novel-synthesis-not-template
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled this pass)
- scope: v3 generation
- decision: The OS synthesises a NOVEL agent (actual new code), not a
  parameterised template and not a composition of pre-vetted components — both
  weaker readings presuppose a coder upstream and fail the non-coder promise.

## DEC-world-b-deterministic-gate-floor
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled, hard dependency of v3)
- scope: v3 safety posture
- decision: Post-deploy safety must rest on the deterministic gate physically
  preventing a manifest breach regardless of agent code ("world B"), not on
  the security LLM having read the code correctly. Auto-deploy-on-green is
  defensible only in world B.

## DEC-manifest-not-readable-by-agent
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled)
- scope: v3 safety posture
- decision: The manifest is privileged-read for the gate and NOT visible to
  the agent at all (stronger than read-only). An agent that can read its own
  allowlist can hug the boundary precisely; one that cannot must guess.

## DEC-review-mode-vs-permission-visibility-orthogonal
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled)
- scope: deploy policy
- decision: Two orthogonal axes that must not be collapsed. Axis 1 — review
  mode (--always-review | --review-if-risky | --dangerously-skip-review),
  governs whether deploy blocks on a human, sits above the gate, never permits
  crossing it. Axis 2 — permission visibility, always on, no flag, the
  capability grant is always shown at deploy. The envelope (read-only /
  no-egress / spend-under-threshold) is a deterministic predicate over manifest
  fields, never an LLM judgement.

## DEC-enforcement-precedes-generation
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled, "cannot be reshuffled")
- scope: roadmap ordering
- decision: The single ordering constraint that cannot be reshuffled:
  enforcement must precede generation. Enforcement earns trust on easy mode
  (human authors) before generation makes it load-bearing on hard mode.

## DEC-runtime-beam-otp-elixir-now
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled, with Gleam deferred-not-rejected)
- scope: runtime substrate
- decision: BEAM/OTP is the control plane (supervisors, schedulers, mailboxes,
  state-owners); heavy LLM work runs in Python/PydanticAI across a port/HTTP
  boundary. Elixir now (most reps, OTP is what's needed); revisit Gleam when
  building the gate. A Python agent crash/OOM must surface to its BEAM
  supervisor as a clean process exit.

## DEC-mvp-is-v3-not-v0
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- status: proposed (settled)
- scope: scope / milestones
- decision: v0 is a structural milestone (walking skeleton), explicitly not an
  MVP. The MVP is v3 (generation from purpose). v3 is itself an entire
  roadmap and must be re-mapped as its own release sequence, not treated as
  one release.
