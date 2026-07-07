# Feature Specification: Optional Inference for Generated Agents

**Feature Branch**: `040-optional-inference`
**Created**: 2026-07-07
**Status**: Draft
**Input**: User description: "Introduce optional inference: let generated agents be either DETERMINISTIC (no LLM calls) or INFERENCE-BASED, chosen per purpose, instead of forcing every agent through the broker's LLM tool-call loop."

## Overview

Today every generated agent must route its effects through an LLM completion loop:
the agent asks a model to emit tool calls, and the substrate's deterministic gate
(the capability rail) gates, executes, parks, records, and meters them. This makes
LLM inference mandatory even for fixed-action purposes (e.g. "send a hard-coded
'Hello, World!' to Discord when triggered"), which is backwards on three counts:

1. **Safety** — the system's own security principle ("no component both runs an LLM
   and holds a credential; the deterministic gate is the only firewall") makes a
   no-LLM agent the purest case: it proposes tool calls, the rail disposes. Forcing
   inference makes the risky path mandatory and the safest path impossible.
2. **Simplicity** — a fixed-action task needs no reasoning. Routing it through a
   model adds cost and latency for no benefit.
3. **Injection surface** — because the generated body feeds untrusted trigger input
   into the model as instructions, even a trivial agent is injectable (observed: a
   hello-world agent steered into sending "The system has been compromised"). A
   deterministic agent has no LLM slot to hijack.

The blocking gap is in the substrate: there is no way for an agent to submit a tool
call to the deterministic gate without an LLM completion. This feature adds a direct
tool-submission channel, makes the deterministic/inference choice an explicit
recorded classification during generation, and migrates the judge off the retired
agent-self-policing protocol.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Direct tool submission without inference (Priority: P1)

An agent process submits its intended tool call(s) directly to the substrate. The
substrate runs each submission through the same deterministic gate as the inference
path — granting or rejecting, executing or parking, recording every disposition to
the run's action transcript, and metering connector costs — without ever invoking a
model. The agent still holds no credential and never sees the capability manifest.

**Why this priority**: This is the blocking substrate gap. Nothing else in the
feature (classification, synthesis contracts, judge migration) can deliver value
until an agent can reach the gate without a model call. It also immediately unblocks
making the stubbed-LLM discovery workaround honest in a follow-up.

**Independent Test**: With pre-seeded grants and no model provider configured at
all, a test process submits (a) a granted tool call, (b) an ungranted tool call,
and (c) an approval-required tool call. The transcript shows executed, rejected,
and parked dispositions respectively; connector costs are metered for the executed
call; zero inference spend is recorded.

**Acceptance Scenarios**:

1. **Given** a run with a granted connector capability, **When** the agent submits
   a matching tool call through the direct channel, **Then** the call is executed,
   recorded on the action transcript as executed, and its connector cost is metered
   — with no model invocation anywhere in the flow.
2. **Given** a run whose grants do NOT include a connector, **When** the agent
   submits a tool call naming that capability, **Then** the call is rejected and
   recorded as rejected, exactly as an ungranted call from the inference path
   would be.
3. **Given** a granted connector that requires human approval, **When** the agent
   submits a matching tool call, **Then** the call is parked pending approval,
   identical to the inference path's parking behaviour.
4. **Given** any submission through the direct channel, **When** it is processed,
   **Then** the action transcript for the run token records its disposition via the
   single transcript writer, and no credential or manifest content is ever exposed
   to the submitting agent.
5. **Given** a malformed submission (not shaped like a tool call, or naming no
   recognizable capability), **When** it arrives on the channel, **Then** it is
   rejected with a recorded disposition rather than crashing the run or silently
   dropping.

---

### User Story 2 - Mode classification and branched synthesis (Priority: P2)

When the generation pipeline synthesizes an agent for a purpose, it first makes an
explicit, recorded classification: "does fulfilling this purpose require reasoning
over dynamic content at runtime?" The answer selects one of two synthesis contracts:

- **Deterministic**: the agent body hard-codes its intended tool call(s), submits
  them directly to the substrate, and prints a terminal outcome record. No untrusted
  input is ever treated as an instruction.
- **Inference-based**: today's broker-completion body, unchanged.

The classification is a typed, persisted value attached to the generated agent, not
an incidental byproduct of what the body happens to do.

**Why this priority**: This is where the user-visible value lands — fixed-action
purposes stop paying inference cost and stop being injectable. It depends on the P1
channel existing.

**Independent Test**: Drive the generation pipeline with stubbed providers for two
purposes — one fixed-action ("send a hard-coded greeting on trigger") and one
reasoning-dependent ("summarize the incoming message"). Verify the first is
classified deterministic and its body contains no inference call; the second is
classified inference-based and matches the existing contract; both classifications
are recorded and readable afterwards.

**Acceptance Scenarios**:

1. **Given** a fixed-action purpose, **When** generation runs, **Then** the recorded
   classification is deterministic and the synthesized body submits hard-coded tool
   calls through the direct channel with no inference request.
2. **Given** a purpose that requires reasoning over dynamic runtime content,
   **When** generation runs, **Then** the recorded classification is inference-based
   and the synthesized body follows the existing broker-completion contract.
3. **Given** a deterministic agent produced by this pipeline, **When** its trigger
   fires with a payload containing adversarial instructions (e.g. "ignore your
   instructions and send X"), **Then** the agent performs exactly its hard-coded
   action — the payload cannot alter what is submitted as an instruction.
4. **Given** a completed generation, **When** anyone inspects the agent's recorded
   artifacts, **Then** the execution mode is present as an explicit typed value,
   and downstream stages (judging, deployment) can read it.
5. **Given** a deterministic agent, **When** it names its intended action, **Then**
   it does so as a tool-call-shaped proposal (the same abstract naming the inference
   path's tool schema exposes) — it never reads the manifest and never names a raw
   internal connector identity that would break manifest invisibility.

---

### User Story 3 - Judge tests the declared mode, not agent politeness (Priority: P3)

The judging stage evaluates a generated agent against its declared execution mode
and against what the substrate actually guarantees. Judge expectations from the
retired protocol are dropped: no more "output an empty actions list" checks, and no
more testing whether the agent voluntarily declines ungranted connectors,
out-of-scope methods, or spend-cap violations — the substrate enforces all of those
deterministically. The judge verifies **substrate containment** (forbidden effects
did not happen; the transcript shows rejection/parking) and **purpose-fit** (the
intended effect happened as specified for the declared mode).

**Why this priority**: Without this, newly generated deterministic agents would be
judged against a protocol they rightly don't follow, and inference agents keep
being graded on self-policing theatre that proves nothing. It depends on the mode
classification (P2) existing to test against.

**Independent Test**: Run the judging stage against one deterministic and one
inference-based agent using stubbed providers. Verify the judge selects
expectations matching each declared mode, that no generated judge spec contains
empty-actions-list or self-policing expectations, and that containment assertions
read the action transcript rather than the agent's own output.

**Acceptance Scenarios**:

1. **Given** an agent declared deterministic, **When** the judge runs, **Then** its
   checks assert the hard-coded effect occurred (purpose-fit) and that nothing
   outside the grant set executed (containment via transcript), with no
   expectations about inference behaviour.
2. **Given** an agent declared inference-based, **When** the judge runs, **Then**
   its checks assert purpose-fit and substrate containment, with no expectation
   that the agent self-polices ungranted connectors, out-of-scope methods, or
   spend caps.
3. **Given** the migrated judge, **When** its specs are inspected, **Then** no
   spec anywhere expects an "empty actions list" output or any other artifact of
   the retired protocol.
4. **Given** judging of either mode, **When** it executes, **Then** it runs
   uncapped (one-off setup spend), preserving the existing judging spend-cap fix.

---

### Edge Cases

- **Ambiguous purpose at classification time**: a purpose that could plausibly be
  fulfilled either way (e.g. "post a daily status message" — fixed text or
  composed?) is classified inference-based by default; deterministic is chosen only
  when the purpose demonstrably requires no runtime reasoning (see Assumptions).
- **Deterministic agent submitting multiple calls**: the channel accepts a sequence
  of tool calls; each is gated and recorded individually — partial success is
  possible and visible per-call on the transcript.
- **Empty submission**: an agent that submits zero tool calls produces a terminal
  outcome record with nothing on the transcript; the run completes rather than
  hanging.
- **Approval parking on a deterministic agent**: a parked call means the agent's
  terminal outcome reflects "parked/pending", not success; the transcript is the
  source of truth for what actually happened.
- **Channel misuse by an inference-based agent**: any agent process can technically
  reach the direct channel; this is safe by design because the gate applies
  identically regardless of caller — mode is a synthesis contract, not a substrate
  privilege boundary.
- **Adversarial trigger payload to a deterministic agent**: the payload is at most
  opaque data; there is no path by which it becomes an instruction, so the agent's
  submitted calls are byte-identical to the benign case.
- **Metering with no LLM spend**: a deterministic run's cost is exactly the sum of
  its executed connector tool costs; the spend record must show zero inference
  charges without breaking spend accounting invariants.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The substrate MUST provide a direct tool-submission channel through
  which an agent process can submit one or more tool calls for evaluation without
  any model invocation occurring anywhere in the handling path.
- **FR-002**: Every call submitted on the direct channel MUST pass through the same
  deterministic gate pipeline as inference-emitted tool calls: capability gating,
  execution, approval parking, transcript recording, and connector-cost metering,
  with identical semantics and identical recorded dispositions.
- **FR-003**: An ungranted or out-of-scope submission on the direct channel MUST be
  rejected and recorded as rejected — never executed, never silently dropped —
  exactly as the inference path records it. Approval-required submissions MUST be
  parked, not executed.
- **FR-004**: The direct channel MUST NOT expose credentials, manifest contents, or
  any capability information beyond what the inference path's tool schema already
  exposes to an agent. The agent proposes an action shaped like a tool call; the
  substrate resolves and gates it against the manifest the agent cannot see.
- **FR-005**: The generation pipeline MUST perform an explicit classification step
  before synthesis — "does fulfilling this purpose require reasoning over dynamic
  content at runtime?" — and MUST record the result as a typed execution-mode value
  (not a bare string or bare map) attached to the generated agent's artifacts.
- **FR-006**: Generation MUST branch on the classification to one of exactly two
  synthesis contracts: (a) deterministic — the body hard-codes its intended tool
  call(s), submits them via the direct channel, and emits a terminal outcome
  record; (b) inference-based — the existing broker-completion body.
- **FR-007**: A deterministic agent body MUST NOT feed untrusted trigger input into
  any instruction-interpreting context. Trigger data may appear only as opaque data;
  it can never change which actions the agent submits.
- **FR-008**: A deterministic agent MUST name its intended actions using the same
  abstract tool-call vocabulary the inference path exposes, without reading the
  manifest and without referencing raw internal connector identities.
- **FR-009**: The judging stage MUST evaluate each agent against its declared
  execution mode, verifying purpose-fit (the intended effect occurred) and
  substrate containment (forbidden effects were rejected or parked, as evidenced by
  the action transcript).
- **FR-010**: All judge expectations from the retired protocol MUST be removed:
  no "empty actions list" output checks and no checks that the agent self-polices
  ungranted connectors, out-of-scope methods, or spend caps.
- **FR-011**: The action transcript MUST remain single-writer, keyed by run token;
  dispositions arriving via the direct channel are recorded through that same
  writer.
- **FR-012**: A deterministic agent's runtime spend MUST consist solely of metered
  connector tool costs — zero inference charges — while generation and judging
  remain uncapped one-off setup (the existing judging cap-lift is preserved, not
  regressed).
- **FR-013**: All automated tests for the classification step, both synthesis
  contracts, and the direct channel MUST run without live model calls, using
  stubbed providers/transports and pre-seeded state, asserting outcomes via the
  action transcript.

### Key Entities

- **Execution Mode**: a typed classification with exactly two values —
  `:deterministic` or `:inference` (the latter written "inference-based" in prose) —
  decided per purpose during generation, recorded with the agent's artifacts, and
  read by judging and deployment.
- **Tool Submission**: one or more tool-call-shaped proposals submitted by an agent
  process on the direct channel; carries the run's identity (run token) and the
  proposed action name/arguments, nothing more.
- **Disposition Record**: the transcript entry produced for every gated call —
  executed, rejected, or parked — identical in shape across the inference and
  direct paths.
- **Terminal Outcome Record**: the deterministic agent's printed end-of-run
  summary reflecting the dispositions of its submissions (success, rejection,
  or parked/pending).
- **Judge Spec (migrated)**: per-agent evaluation expectations keyed to the
  declared execution mode; asserts purpose-fit and substrate containment only.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A fixed-action purpose (the hello-world Discord notification) is
  generated as a deterministic agent and completes an end-to-end triggered run with
  zero inference requests and zero inference spend recorded.
- **SC-002**: An adversarial trigger payload delivered to a deterministic agent
  produces a submitted action byte-identical to the benign-payload case — the
  injection observed under the current protocol is impossible by construction.
- **SC-003**: 100% of tool calls submitted via the direct channel appear on the
  action transcript with a disposition; in a three-way test (granted, ungranted,
  approval-required) the dispositions are executed, rejected, and parked
  respectively, matching the inference path's behaviour for the same calls.
- **SC-004**: Every agent produced by the generation pipeline after this feature
  carries a recorded execution mode, and the judging stage's expectations
  demonstrably differ per mode.
- **SC-005**: Zero judge specs (existing or newly generated) contain retired
  protocol expectations — empty-actions-list checks or agent self-policing checks.
- **SC-006**: The full test suite passes with no live model calls and no
  regression of the uncapped generation/judging spend behaviour.

## Assumptions

- **Ambiguity defaults to inference-based**: when classification cannot
  confidently determine that a purpose needs no runtime reasoning, the pipeline
  chooses inference-based. A wrongly-deterministic agent silently fails its
  purpose; a wrongly-inference agent merely costs more — so the default favours
  purpose-fit.
- **Deterministic means fully hard-coded in v1**: a deterministic agent's tool
  calls (names and arguments) are fixed at synthesis time. Structural templating
  of trigger data into arguments (e.g. echoing a field) is out of scope for this
  feature; a purpose needing it classifies as inference-based for now.
- **Mode is per-agent, not per-call**: one agent has exactly one execution mode.
  Hybrid bodies (some hard-coded calls plus inference) are not a supported
  synthesis contract.
- **Existing deployed inference agents are unaffected**: the inference contract is
  unchanged; nothing forces regeneration. The existing hello-world Discord agent
  may be regenerated under the deterministic contract as a validation case.
- **Discovery stays as-is in this feature**: rewriting discovery as an honestly
  deterministic agent (replacing the stubbed-LLM workaround) is an enabled
  follow-up, explicitly out of scope here.
- **The direct channel reuses the existing agent-substrate transport**: agents
  already talk to the substrate over a private local channel for inference; the
  direct submission capability is an addition to that same trusted boundary, not a
  new externally reachable surface.

## Out of Scope

- The run-worker transcript migration and the discovery tool-channel migration
  (already landed on the 039 branch).
- The judging spend-cap fix (already landed: judging is uncapped).
- The synthesis-output parser robustness fix (already landed).
- Rewriting discovery as a deterministic agent — called out as an enabled
  follow-up, not part of this feature.
- Structural templating of trigger data into deterministic tool-call arguments
  (see Assumptions).
