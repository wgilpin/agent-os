# Feature Specification: Stage 4 Write the Novel Agent Body (write-novel-agent)

**Feature Branch**: `015-write-novel-agent`  
**Created**: 2026-06-30  
**Status**: Draft  
**Input**: User description: "Stage 4 of the v3 six-stage generation pipeline — WRITE THE NOVEL AGENT BODY. Synthesise genuinely NEW Python/PydanticAI agent code that fulfils the confirmed purpose under the machine-written manifest — not template-filling, not composition of pre-built blocks, but novel code the OS authors itself. Inputs are the confirmed purpose plus the machine-written manifest emitted by Stage 2. The judge spec is NOT an input and MUST NOT be read — the agent is generated blind to the test cases. The synthesised code runs as a sandboxed, UNTRUSTED workload across the BEAM↔Python port boundary; it reaches capabilities only through the substrate and inference only by calling back through the InferenceBroker UDS, holds no credential, and sees no manifest."

## Overview

Stage 4 is the fourth stop in the v3 generation pipeline and the one that makes the
headline Phase-4 claim literally true: **the OS authors an agent**. It takes the
confirmed purpose and the machine-written manifest that Stage 2 produced, and synthesises
a *novel* Python/PydanticAI agent body — genuinely new code written to satisfy this
specific purpose, not a parameterised template and not a wiring-together of pre-built
blocks. The output is the agent body only; this stage does not converse with the user,
does not touch the judge, does not run security review, and does not deploy.

Two structural commitments define the stage. First, it is generated **blind to the
judge**: the judge spec from Stage 3 is never read, so the agent and its tests each derive
independently from manifest + purpose and cannot agree on a shared misread — the other
half of the co-generation-caveat mitigation. Second, the synthesised code is **untrusted
by construction**: the fact the OS wrote it confers no authority. It runs in the existing
sandbox behind the same deterministic gate that already enforces hand-written agents
(proven airtight in v2). Stage 4 points the generator at that enforcement; it does not
invent a parallel safety rail.

The agent body Stage 4 emits reaches capabilities only through the substrate (gate /
effector / credential-proxy) and reaches inference only by calling back through the
substrate inference chokepoint over the port boundary. It holds no model credential and is
given no path to read its own manifest, caps, prices, or usage. The single model call that
*writes* the code routes through that same metered, credential-isolated chokepoint.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Synthesise a novel agent body from purpose + manifest (Priority: P1)

The pipeline hands Stage 4 a confirmed purpose and the machine-written manifest for one
agent. Stage 4 produces a new, runnable agent body, placed where the substrate provisions
agents from, that is written specifically to fulfil that purpose within that manifest's
grants. The body is not a fill-in of a fixed template and not an assembly of canned
components — it is novel code authored for this purpose.

**Why this priority**: P1. This is the defining capability of Stage 4 and of Phase 4 as a
whole. Without a synthesised agent body there is nothing for the later stages
(security-review, deploy) to act on and nothing for the runtime gate to govern.

**Independent Test**: Provide a confirmed purpose and a valid manifest in a test, run the
synthesis, and assert that (a) an agent body is produced at the provisioning location for
that agent name, (b) the body reads one line of typed input on stdin and emits typed
proposed actions/output matching the port-workload contract the substrate validates, and
(c) two different purposes yield materially different bodies rather than the same skeleton
with substituted parameters.

**Acceptance Scenarios**:

1. **Given** a confirmed purpose and its machine-written manifest, **When** Stage 4 runs,
   **Then** it emits an agent body whose stated job corresponds to the purpose and whose
   input/output handling conforms to the existing typed port-workload contract.
2. **Given** two confirmed purposes that differ in intent, **When** each is synthesised,
   **Then** the two emitted bodies differ in their logic (the synthesis is purpose-driven,
   not a constant template with swapped fields).
3. **Given** a synthesised agent body, **When** its input and proposed-action shapes are
   inspected, **Then** they are strongly typed and match the contract the substrate
   validates on the BEAM side.

---

### User Story 2 - Generated blind to the judge (Priority: P1)

Stage 4 synthesises the agent without ever reading the judge spec produced by Stage 3. The
agent derives only from manifest + purpose, so it shares no test-case context with the
judge that will later evaluate it.

**Why this priority**: P1. This blindness is half of the co-generation-caveat mitigation.
If the agent could see the test cases it is judged against, a spec misread could be
laundered into spurious agreement between the code and its own tests, defeating the
independent-derivation guarantee the judge stage was built to provide.

**Independent Test**: Run synthesis in an environment where the judge spec exists, and
assert that the synthesis neither reads nor receives it — the only inputs consumed are the
purpose and the manifest.

**Acceptance Scenarios**:

1. **Given** a judge spec exists for the agent, **When** Stage 4 synthesises the body,
   **Then** the synthesis does not read the judge spec and its result is unaffected by the
   spec's presence or contents.
2. **Given** the inputs to synthesis, **When** they are enumerated, **Then** they are
   exactly the confirmed purpose and the machine-written manifest — nothing from Stage 3.

---

### User Story 3 - The body holds no manifest and no credential (Priority: P1)

The agent body Stage 4 emits has no path to read its own manifest, caps, prices, or usage,
and holds no model credential. It reaches capabilities only by proposing actions to the
substrate and reaches inference only by calling back through the substrate inference
chokepoint over the port boundary.

**Why this priority**: P1. The manifest-not-readable invariant and the single inference
chokepoint are load-bearing safety properties. An agent that can see its own allowlist can
hug the boundary precisely; an agent holding a credential or opening a direct provider path
escapes the metered, enforced chokepoint. Stage 4 must introduce no such path even though
full end-to-end re-verification of the invariant lives in a later stage.

**Independent Test**: Inspect the emitted body and its execution scaffolding and assert
there is no manifest/spend/price/usage input reachable by the code, no embedded model
credential, and no inference route other than the substrate chokepoint.

**Acceptance Scenarios**:

1. **Given** a synthesised agent body, **When** its inputs and environment are examined,
   **Then** the manifest, caps, prices, and usage are not among them and are not reachable.
2. **Given** the body needs inference at runtime, **When** its inference path is examined,
   **Then** it calls back through the substrate inference chokepoint over the port
   boundary and holds no model credential of its own.
3. **Given** the body needs a privileged effect, **When** its capability path is examined,
   **Then** it proposes the action to the substrate rather than performing the effect
   directly.

---

### User Story 4 - Untrusted code, single generation chokepoint (Priority: P2)

The one model call that writes the agent code routes through the substrate's inference
chokepoint — the same metered, credential-isolated path the rest of the system uses. Stage
4 holds no model credential of its own and opens no second provider path. The emitted body
is treated as untrusted regardless of the fact the OS produced it.

**Why this priority**: P2. It hardens the generation step itself. Routing the authoring
call through the existing chokepoint keeps spend metered and credentials isolated even
while the OS is writing code, and it keeps the trust posture honest: machine-authored code
earns no special standing.

**Independent Test**: Run synthesis and assert the authoring model call is issued through
the substrate inference chokepoint, that Stage 4 carries no provider credential, and that
no alternative provider path is opened.

**Acceptance Scenarios**:

1. **Given** Stage 4 needs to author code, **When** it makes its model call, **Then** the
   call goes through the substrate inference chokepoint and not a direct provider call.
2. **Given** the generation step, **When** its credentials are examined, **Then** Stage 4
   holds no model key and the emitted body holds none either.

---

### Edge Cases

- **Synthesis returns code that does not parse or does not honour the typed port-workload
  contract.** Stage 4 fails closed for that agent and emits no body, so no later stage runs
  on an unusable artifact. (Deep adversarial code review is a later stage's job, not this
  one's — see Out of Scope.)
- **The authoring model call fails** (timeout, error, or spend breach at the chokepoint).
  Stage 4 fails closed and emits no body; it never substitutes a fallback or a direct
  provider call to "rescue" the generation.
- **The judge spec is present on disk** when synthesis runs. It is ignored entirely; its
  presence or contents must not change the result.
- **A purpose implies a capability the manifest does not grant.** Stage 4 still emits the
  body it can author for the purpose; it does not widen, rewrite, or re-emit the manifest
  (that is Stage 2's artifact), and the runtime gate remains the boundary that refuses
  ungranted actions.
- **The same purpose + manifest is synthesised more than once.** Each run independently
  produces a body that satisfies the contract; bodies need not be byte-identical (synthesis
  is generative, unlike Stage 2's deterministic projection).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Stage 4 MUST synthesise a novel Python/PydanticAI agent body that fulfils the
  confirmed purpose — new code authored for this purpose, not a parameterised template and
  not a composition of pre-built components.
- **FR-002**: Stage 4 MUST take as input ONLY the confirmed purpose and the machine-written
  manifest emitted by Stage 2; it MUST consume no other artifact to author the body.
- **FR-003**: Stage 4 MUST NOT read the judge spec produced by Stage 3, and its output MUST
  be unaffected by that spec's presence or contents.
- **FR-004**: The emitted agent body MUST conform to the existing typed port-workload
  contract — read one line of typed input on stdin and emit typed proposed actions/output
  — using strongly-typed models for both its input and its proposed-action output.
- **FR-005**: Stage 4 MUST place the emitted body where the substrate provisions agents
  from, under the agent's own name, so it can run as a sandboxed workload across the port
  boundary.
- **FR-006**: Stage 4 MUST NOT bake the manifest into the agent body and MUST give the
  emitted code no path to read its own manifest, caps, prices, or usage.
- **FR-007**: The emitted body MUST reach privileged capabilities only by proposing actions
  to the substrate (gate / effector / credential-proxy), never by performing the effect
  directly.
- **FR-008**: The emitted body MUST reach inference only by calling back through the
  substrate inference chokepoint over the port boundary, MUST hold no model credential, and
  MUST open no direct provider path.
- **FR-009**: The single model call that authors the agent code MUST route through the
  substrate inference chokepoint; Stage 4 MUST hold no model credential of its own and MUST
  open no second provider path.
- **FR-010**: Stage 4 MUST treat the emitted body as untrusted and MUST NOT grant it any
  authority on the basis that the OS wrote it; it MUST point the generated agent at the
  existing deterministic enforcement rather than inventing a parallel one.
- **FR-011**: Stage 4 MUST verify, before emitting, that the synthesised body parses and
  honours the typed port-workload contract; if it does not, Stage 4 MUST fail closed and
  emit no body for that agent.
- **FR-012**: If the authoring model call fails (timeout, error, or spend breach at the
  chokepoint), Stage 4 MUST fail closed and emit no body; it MUST NOT fall back to a direct
  provider call or a canned body.
- **FR-013**: Stage 4 MUST NOT run, evaluate, deploy, or security-review the agent, and
  MUST NOT build or modify the gate or runtime enforcement.

### Key Entities *(include if feature involves data)*

- **Confirmed Purpose**: The human-confirmed statement of what the agent is for, carried
  forward from the elicitation stage; one of the two sole inputs to synthesis.
- **Machine-Written Manifest**: The Stage 2 output declaring purpose + capability grant +
  boundary contract + spend; the second sole input. Stage 4 reads it to author code *toward*
  it but never embeds it in, or exposes it to, the emitted body.
- **Synthesised Agent Body**: The novel Python/PydanticAI workload Stage 4 emits — typed
  stdin input, typed proposed-action output, inference via the substrate chokepoint, no
  manifest, no credential — placed at the agent's provisioning location.
- **Typed Port-Workload Contract**: The existing strongly-typed input/proposed-action shape
  that substrate-side validation enforces; the contract the emitted body must satisfy.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For a confirmed purpose and its manifest, Stage 4 produces an agent body that
  honours the typed port-workload contract (typed stdin in, typed proposed-actions out) in
  100% of successful runs.
- **SC-002**: Across two or more distinct purposes, the emitted bodies differ in their
  logic — demonstrating novel, purpose-driven synthesis rather than a constant template
  with substituted fields.
- **SC-003**: In 100% of runs, the emitted body contains no manifest/caps/prices/usage
  input and no embedded model credential, and its only inference route is the substrate
  chokepoint.
- **SC-004**: In 100% of runs, the judge spec is neither read nor consumed; synthesis output
  is identical whether or not a judge spec is present.
- **SC-005**: When synthesis returns unusable code or the authoring model call fails, Stage
  4 emits no body and surfaces the failure in 100% of such cases (fail-closed), leaving no
  partial or fallback artifact for later stages.
- **SC-006**: The authoring model call is observed to route through the substrate inference
  chokepoint in 100% of runs, with no direct provider call and no second credential path.

## Assumptions

- **Output shape mirrors the existing port workloads.** "The agent body" is taken to mean a
  runnable port-workload package at the agent's provisioning location, following the same
  layout as the existing hand-written agents (a typed entry workload plus its typed
  input/proposed-action models and whatever packaging the substrate already expects). If a
  narrower output (entry module only) is intended, that narrows scope but does not change
  the safety requirements above.
- **Stage 4's acceptance check is structural, not adversarial.** Before emitting, Stage 4
  verifies the body parses and honours the typed contract and introduces no manifest or
  direct-provider path of its own. Deep "is this code written to satisfy the purpose without
  breaching the manifest" judgement is explicitly the security-review stage's job (04-08),
  and full end-to-end re-verification of the manifest-not-readable invariant for the
  machine-written manifest + code is 04-09 — not duplicated here.
- **Synthesis is generative, not deterministic.** Unlike Stage 2's pure projection, two runs
  on the same input may yield different (but contract-satisfying) bodies; byte-for-byte
  reproducibility is not required of this stage.
- **Provider/transport choice is broker infrastructure.** Which upstream model or transport
  the inference chokepoint uses is out of Stage 4's scope; Stage 4 only routes through the
  existing chokepoint.
- **The confirmed purpose and machine-written manifest already exist** as the outputs of the
  done upstream stages (04-04 elicitation, 04-05 manifest emission); Stage 4 consumes them
  and re-emits neither.
- **The existing sandbox and deterministic gate are reused unchanged.** Stage 4 relies on
  the already-proven isolation (read-only filesystem except scratch, no network egress
  except via substrate connectors, crash/OOM surfaced) and the v2 gate; it builds no new
  enforcement.

## Out of Scope

- **Elicitation (04-04, done)** and **manifest emission (04-05, done)** — Stage 4 consumes
  their outputs; it does not re-run or re-emit them.
- **Judge synthesis (04-06, done)** — Stage 4 neither writes nor reads the judge, and MUST
  NOT read the judge spec.
- **Security-review agent (04-08)** — reading the code to judge "written to satisfy purpose
  without breaching manifest" is a later, separate stage.
- **Deploy-on-green and the both-must-pass gate (04-09)**, including the re-verification of
  the manifest-not-readable invariant for the machine-written manifest + code.
- **The review-mode / envelope rail (04-03)** and **the E2E MVP thread (04-10)**.
- **Running, evaluating, or deploying the agent**, and **building or modifying the gate or
  runtime enforcement** — none happen in this stage.
- **Provider/transport choice for the inference chokepoint** — that is broker
  infrastructure, not a Stage 4 concern.
