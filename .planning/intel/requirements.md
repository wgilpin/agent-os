# Requirements

Requirements extracted from the PRD `docs/agent_os.md` (Agent OS User Story Map,
classified PRD, medium confidence). The story map organizes capabilities by
Activity → Step → release (R1=v0, R2=v1, R3=v2, R4=v3). Each requirement below
preserves its release tag and the story-map node id.

The plan checklist `docs/plan.md` (DOC) restates the same capability set as
unchecked tasks; it is recorded as corroborating context, not a separate
requirement source. No competing acceptance variants were detected — the PRD
and plan agree on scope and sequencing.

---

## Activity: Declare an agent

### REQ-write-manifest
- source: /Users/will/projects/agent_os/docs/agent_os.md (#2KPW)
- acceptance:
  - [R1] Hand-write a markdown manifest, human-kept-in-sync (#bzJO)
  - [R3] Manifest gains boundary-contract fields: recipient scoping, on_breach,
    approval-as-event (#RD81)

### REQ-state-purpose
- source: /Users/will/projects/agent_os/docs/agent_os.md (#FITq)
- acceptance:
  - [R1] Purpose stated as a one-line contract (#P7ju)
  - [R4] Declare a purpose; OS emits the manifest (#qhtA)

### REQ-grant-connectors-mounts
- source: /Users/will/projects/agent_os/docs/agent_os.md (#kfHl)
- acceptance:
  - [R1] Connectors & mounts listed by hand (#yelG)
  - [R4] Manifest carries a normie-readable capability render
    (<READ YOUR GMAIL>, <SEND EMAILS FROM YOUR GMAIL>) (#ia26)
  - [R4] Render is FAITHFUL+TOTAL — every capability appears; may collapse
    detail, never drop one (#UK6Y)
  - [R4] Render is DETERMINISTIC from manifest fields, never LLM-written (#sYnr)
  - [R4] Render is DANGER-RANKED — read looks different from send/egress; the
    user sees WHY it left the envelope (#N14j)

### REQ-set-spend-cap
- source: /Users/will/projects/agent_os/docs/agent_os.md (#5X2o)
- acceptance:
  - [R1] Spend cap as a number (no on_breach yet) (#NXrY)
  - [R3] Spend becomes {cap, window, on_breach} (#Yblo)

## Activity: Provision it from the declaration

### REQ-instantiate-from-declaration
- source: /Users/will/projects/agent_os/docs/agent_os.md (#tsAh)
- acceptance:
  - [R1] Hard-wired config (not provisioned from manifest) (#R5zY)
  - [R2] Provision agent into a container (#zdJv)
  - [R3] Substrate provisions from the enforced manifest (#U3k9)
  - [R4] OS composes/selects template, validates generated manifest is
    well-formed & minimally-scoped (#ocfy)

### REQ-mount-state
- source: /Users/will/projects/agent_os/docs/agent_os.md (#zYXh)
- acceptance:
  - [R1] Roster/trust state mounted to single-writer GenServer (#RLbN)

### REQ-wire-credentials
- source: /Users/will/projects/agent_os/docs/agent_os.md (#CUeC)
- acceptance:
  - [R3] Credential proxy holds caps, injects at request time (#kj6z)

## Activity: Trigger it into motion

### REQ-trigger-time
- source: /Users/will/projects/agent_os/docs/agent_os.md (#uWCd)
- acceptance:
  - [R1] One timer (daily 07:00 emergence signal) (#8beo)

### REQ-trigger-event
- source: /Users/will/projects/agent_os/docs/agent_os.md (#KjA1)
- acceptance:
  - [R3] Event-trigger + approval-as-event-trigger (#1wOw)

### REQ-trigger-message
- source: /Users/will/projects/agent_os/docs/agent_os.md (#KEa1)
- acceptance:
  - [R3] Message-trigger (you, via chat, are another process) (#jQWl)

## Activity: Run it (LLM does the work)

### REQ-hand-input
- source: /Users/will/projects/agent_os/docs/agent_os.md (#bvJu)
- acceptance:
  - [R1] One port → human-written Python discovery agent (#SCA3)
  - [R2] Agent runs sandboxed; safe against injected bookmark/tweet (#9icU)
  - [R4] OS synthesises a NOVEL agent body (new code, not template/compose) (#U9XU)

### REQ-reason-over-input
- source: /Users/will/projects/agent_os/docs/agent_os.md (#lLQo)
- acceptance:
  - [R1] LLM reasons over input (unsanitized at v0) (#L8KL)
  - [R2] Reasons over sanitized untrusted web input (#4Hf2)

### REQ-propose-enumerated-actions
- source: /Users/will/projects/agent_os/docs/agent_os.md (#SlBh)
- acceptance:
  - [R1] Proposes enumerated actions (#JWKm)

## Activity: Gate its outputs before effect

### REQ-validate-action-vs-grants
- source: /Users/will/projects/agent_os/docs/agent_os.md (#1dB6)
- acceptance:
  - [R1] Minimal output check (not enforcement) (#EvrB)
  - [R3] Deterministic gate: every action validated vs enumerated grants +
    constraints (#4f3m)
  - [R4] Gate now checks a machine-written manifest (new trust posture) (#424K)
  - [R4] Gate must hold against machine-written CODE: post-deploy safety rests
    on the gate, not the security LLM's reading (world B) (#i1aF)
  - [R4] Manifest is NOT readable by the agent — privileged-read for the gate
    only (#Lj8X)
  - [R4] INVARIANT: --dangerously-skip-review is deploy-review skip ONLY; the
    gate still enforces the manifest at runtime (#biWi)

### REQ-inject-credential
- source: /Users/will/projects/agent_os/docs/agent_os.md (#lgL7)
- acceptance:
  - [R3] Credential proxy injects at the chokepoint (#Z5MD)

### REQ-meter-spend
- source: /Users/will/projects/agent_os/docs/agent_os.md (#z0ey)
- acceptance:
  - [R3] Spend metered at the deterministic chokepoint (#Jh9U)

### REQ-act-on-behalf
- source: /Users/will/projects/agent_os/docs/agent_os.md (#3BMV)
- acceptance:
  - [R1] Privileged action on agent's behalf (deterministic) (#udar)

## Activity: Observe what exists & what it did

### REQ-list-inventory
- source: /Users/will/projects/agent_os/docs/agent_os.md (#KJpY)
- acceptance:
  - [R1] Standing inventory of what exists (#AiqA)
  - [R4] Security-review verdict + judge result shown in the standing inventory
    (never 'ask the agent') (#yITP)
  - [R4] Permission summary ALWAYS shown at deploy, every mode (display, not a
    decision) — legibility has no flag (#5bNK)
  - [R4] Inventory records provenance: reviewed = human | skipped-in-envelope |
    dangerously-skipped (#Bpa2)

### REQ-read-run-trace
- source: /Users/will/projects/agent_os/docs/agent_os.md (#Y8zJ)
- acceptance:
  - [R1] A legible run-log (#hJ7t)

### REQ-see-spend
- source: /Users/will/projects/agent_os/docs/agent_os.md (#nTGk)
- acceptance:
  - [R3] Per-agent spend visible from the chokepoint (#M1RM)

### REQ-check-conformance
- source: /Users/will/projects/agent_os/docs/agent_os.md (#6BE0)
- acceptance:
  - [R4] Conformance auditor: stated purpose vs observed behaviour, flag-only (#HsQg)
  - [R4] Auditor flags drift to human; human stays on approve-path (#kJkm)

## Activity: Supervise its lifecycle & failures

### REQ-restart-policy
- source: /Users/will/projects/agent_os/docs/agent_os.md (#c93t)
- acceptance:
  - [R1] Restart-once-and-alert policy (#1SUB)

### REQ-kill-on-breach
- source: /Users/will/projects/agent_os/docs/agent_os.md (#hvGK)
- acceptance:
  - [R3] Spend-cap-on-breach becomes a real kill (#9s3O)

### REQ-surface-child-crash
- source: /Users/will/projects/agent_os/docs/agent_os.md (#qLnP)
- acceptance:
  - [R2] Child OOM/crash surfaces as clean BEAM exit (#nfJP)

## Activity: Generate an agent from a stated purpose (v3)

### REQ-elicit-spec
- source: /Users/will/projects/agent_os/docs/agent_os.md (#Krpq)
- acceptance:
  - [R4] Question the user until purpose is clear; minimise everything (KISS) —
    the real defence against spec-misread (#Ennb)

### REQ-gen-manifest
- source: /Users/will/projects/agent_os/docs/agent_os.md (#NXpM)
- acceptance:
  - [R4] Emit manifest from elicited spec; the human-readable manifest is THE
    safety artifact (#nxah)

### REQ-write-judge
- source: /Users/will/projects/agent_os/docs/agent_os.md (#rhj7)
- acceptance:
  - [R4] Synthesise tests; LLM-judged, non-deterministic; certifies
    code-matches-manifest, not manifest-matches-intent (#g7tI)

### REQ-write-novel-agent
- source: /Users/will/projects/agent_os/docs/agent_os.md (#dQqr)
- acceptance:
  - [R4] Synthesise novel agent body (Python/PydanticAI across the port
    boundary) (#tvN8)

### REQ-security-review
- source: /Users/will/projects/agent_os/docs/agent_os.md (#0xZH)
- acceptance:
  - [R4] New agent: reads code+manifest+purpose, judges 'written to satisfy
    purpose without breaching manifest' — smoke detector, not firewall (#zh9b)

### REQ-deploy-on-green
- source: /Users/will/projects/agent_os/docs/agent_os.md (#7jkj)
- acceptance:
  - [R4] On pass from judge AND security review, deploy with no further human
    input — sound ONLY in world B (#w2jd)
  - [R4] Mode --always-review: every deploy blocks on a human (v3-LAUNCH
    DEFAULT; human does the SEMANTIC check, not security) (#wbru)
  - [R4] Mode --review-if-risky: in-envelope (read-only/no-egress/spend<threshold)
    auto-deploys; out-of-envelope blocks (#Kev3)
  - [R4] Mode --dangerously-skip-review: out-of-envelope also auto-deploys (the
    only genuinely dangerous mode) (#qlBT)
  - [R4] Envelope is a DETERMINISTIC predicate over manifest fields — never an
    LLM judgement (#CDuH)
  - [R4] OPEN: should 'conformance auditor live & watching' be a precondition of
    envelope-eligibility? (leaning yes) (#ns0L)
