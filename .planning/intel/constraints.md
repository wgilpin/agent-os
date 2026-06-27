# Constraints

Technical constraints (api-contract | schema | nfr | protocol) extracted from
the ingest set.

Note: No SPEC documents were present in this ingest set. The constraints below
are the contract-shaped commitments embedded in `docs/agent-os-design.md`
(classified DOC). They are recorded here so downstream design has the binding
shapes in one place, but they are NOT formal SPECs — promote to a SPEC if a
hard contract is needed.

---

## CON-manifest-seven-fields
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: schema
- content: The agent manifest has seven core fields, each rendering directly as
  an inventory column: purpose, trigger(s), connectors (+scope), mounts,
  outputs, spend, owner/supervision. The manifest is two schemas in one:
  (1) the capability grant (purpose, triggers, connectors, mounts) describing
  the agent in isolation; (2) the boundary contract (what the substrate
  guarantees in response).

## CON-connector-constraints-subblock
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: schema
- content: `scope: read` is too coarse. Connectors need a `constraints`
  sub-block so recipient/method scoping (e.g. "may use the gmail credential,
  but only to send to allowlisted addresses") lives IN the manifest, not hidden
  in the gate. Otherwise legibility is lost.

## CON-spend-shape
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: schema
- content: Spend is `{cap, window, on_breach}`, not two numbers. A spend cap is
  meaningless without `on_breach` (abort | skip-next-invocation | alert). A
  cost control that fails silent is worse than none.

## CON-approval-as-event-trigger
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: protocol
- content: `requires_approval: true` implies a pending store, a notification
  path, and a second deterministic step that actions approved items. Modelled
  as an event-trigger ("on approval-granted, fire executor") to keep everything
  invocation-scoped and avoid long-lived state.

## CON-enforcement-spine
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: protocol
- content: The three-part enforcement spine:
  manifest (source of truth) → deterministic provisioner (instantiates from
  declaration) → agent run / LLM (reasons over sanitized input, proposes only
  enumerated actions) → deterministic gate (validates every action against the
  manifest's enumerated grants + constraints) → effect (privileged action on
  the agent's behalf). The credential proxy sits at the gate, holds
  capabilities, injects credentials at request time, and is the chokepoint for
  per-agent spend metering.

## CON-synthesis-pipeline-six-stages
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: protocol
- content: The v3 synthesis pipeline is six stages, human-out-of-the-loop after
  the conversation: (1) elicit the spec (question until KISS-clear);
  (2) write the manifest; (3) write the judge (LLM-judged eval-lite, certifies
  code-matches-manifest not manifest-matches-intent); (4) write the novel agent
  body; (5) security review (reads manifest + purpose + code); (6) deploy on
  green (pass from BOTH judge and security review). Deploy may additionally
  block on a human per the review mode.

## CON-review-modes-monotonic
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: protocol
- content: Three review modes on a single monotonic axis where each mode's
  skip-set strictly contains the previous one's: `--always-review` (v3-launch
  default, every deploy blocks on a human), `--review-if-risky` (eventual
  default; in-envelope auto-deploys, out-of-envelope blocks),
  `--dangerously-skip-review` (out-of-envelope also auto-deploys). All three
  sit above the gate; none is permission to cross it. The envelope is a
  deterministic predicate over manifest fields (read-only / no-egress /
  spend-under-threshold), never an LLM judgement.

## CON-permission-render-three-requirements
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: nfr
- content: The normie-readable capability render has three hard requirements:
  (1) Faithful and total — every capability appears; may collapse detail, never
  drop a capability. (2) Deterministically rendered from manifest fields, never
  LLM-written. (3) Danger-ranked in phrasing — `<READ YOUR GMAIL>` and
  `<SEND EMAILS FROM YOUR GMAIL>` must not look alike; the egress/send capability
  is the one that ejects an agent from the auto-deploy envelope.

## CON-gate-is-only-safety-boundary
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: nfr
- content: The deterministic gate is the only safety boundary. LLM review
  layers (security-review, conformance auditor) are probabilistic and must
  never be on the safety-critical path. Conformance auditor authority is
  asymmetric: can raise a flag, can never grant a pass. World B is required for
  v3: the gate must physically prevent any manifest breach regardless of agent
  code — this is the real bar for "v2 done."

## CON-manifest-not-agent-readable
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: nfr
- content: The manifest is privileged-read for the gate and NOT readable by the
  agent at all (stronger than read-only). The agent is the untrusted party the
  manifest is enforced against.

## CON-beam-python-port-boundary
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: protocol
- content: BEAM/OTP is the control plane; LLM agent runs (Python/PydanticAI on
  Vertex/Anthropic) execute across a port/HTTP boundary out to a Python runtime
  or container. Failure semantics must cross the boundary cleanly: a Python
  agent OOMing in a container must surface to its BEAM supervisor as a clean
  process exit so let-it-crash works.

## CON-state-store-concurrency-profiles
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- type: protocol
- content: Different stores get different treatment. Append-only legible logs
  (e.g. the digest log): git-backed markdown (totally-ordered history,
  optimistic concurrency; caveat: git protects bytes not meaning). Contended
  structured state (the roster / trust-propagation KG): single-writer process
  (GenServer) — no locks because no sharing; mutation serialized by
  construction.
