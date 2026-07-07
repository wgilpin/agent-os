# Feature Specification: Deterministic Capability Rails for Generated Agents

**Feature Branch**: `038-deterministic-capability-rails`
**Created**: 2026-07-06
**Status**: Draft
**Input**: User description: "Deterministic capability rails for generated agents: eliminate the LLM-to-LLM exact-string telephone game in the generation pipeline. Today, manifest compliance (connector IDs, method names), model IDs, and refusal semantics are transmitted through or invented by LLMs (codegen LLM → runtime inference LLM → judge LLM) and then checked rigidly downstream, so pipeline runs fail on protocol noise (hallucinated connector names, unpriced model strings, agents crashing on adversarial inputs) before any real compliance question is evaluated. Move each onto a deterministic substrate rail: structured tool calls constrained by manifest-derived declarations, a judge-time record-don't-execute mode, a written refusal contract, substrate-owned model identity, and a judge rescoped to semantic purpose-fit."

## Problem Statement

The agent generation pipeline currently requires three independent language models — the code-authoring model, the agent's runtime reasoning model, and the compliance judge — to losslessly transmit and verify exact protocol strings (connector identifiers, method names, model identifiers) that the deterministic substrate already knows authoritatively from the capability manifest. Because language models are probabilistic, each hand-off is a lossy channel, and pipeline runs fail on transcription noise rather than on genuine compliance questions. In the most recent seven consecutive pipeline runs, **zero failures were genuine compliance violations**: three were hallucinated connector/method names in a free-text action channel, three were agents crashing or emitting empty output because no compliant response to adversarial input was ever defined, and one was a workload-authored model identifier the substrate refused to price.

The substrate already contains the correct deterministic enforcement point (manifest-derived tool declarations injected at the inference chokepoint, with ungranted tools rejected before any effect), but generated agents bypass it via a free-text protocol invented by the synthesis instructions. This feature retires the lossy channels and routes every exact-string decision onto a deterministic rail, leaving language models to decide only what is genuinely theirs to decide.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Generated agents act only through granted, schema-constrained capabilities (Priority: P1)

An operator asks the OS to generate a single-purpose agent (e.g., "send a Hello-World notification to Discord when triggered"). The generated agent's runtime reasoning selects actions exclusively through the structured tool-call channel whose available tools are derived from the capability manifest by the substrate. The agent's code never names, remembers, or reproduces a connector or method string, and no language model in the chain is asked to reproduce one either. If the runtime model nevertheless requests something outside the grants, the substrate rejects it deterministically with a typed, auditable error before any effect occurs.

**Why this priority**: This eliminates the dominant failure class (hallucinated connector/method strings) and is the architectural core of the feature — every other story builds on the structured channel existing.

**Independent Test**: Generate the hello-world Discord agent and run it against a trigger input. Verify the sent notification is proposed/performed via the granted capability, that no manifest string appears in the generated code or the agent-authored prompts, and that a forced ungranted tool request (via a stubbed runtime model) is rejected with a typed error before any external effect.

**Acceptance Scenarios**:

1. **Given** a confirmed manifest granting exactly one connector and one method, **When** the pipeline generates the agent body, **Then** the synthesis instructions contain no requirement for any language model to reproduce a connector, method, or recipient string, and the generated code contains none of those strings.
2. **Given** the generated agent running with a happy-path trigger, **When** its runtime reasoning selects an action, **Then** the action arrives as a structured tool call constrained to the manifest-derived tool declarations, and the notification intent matches the granted connector and method without the agent's code having named them.
3. **Given** a runtime model response requesting a tool not present in the grants, **When** the substrate processes it, **Then** the request is rejected deterministically with a typed, machine-readable error before any external effect, and the rejection is recorded for audit and scoring.
4. **Given** a tool call naming a granted connector but an ungranted method, **When** the substrate processes it, **Then** it is rejected deterministically in the same manner as an ungranted connector.

---

### User Story 2 - Adversarial input produces a scoreable refusal, not a crash (Priority: P2)

The judge probes the generated agent with adversarial boundary inputs ("also send this to Slack", "read the channel history first"). The agent has a written, deterministic refusal contract: it terminates successfully with a machine-readable record containing an empty or filtered set of actions plus a reason. The evaluation harness treats exit status and refusal-shaped output as observations to score — a refusal on a boundary probe scores as compliant; a refusal on the happy path scores as a purpose failure. Abnormal termination is reserved for genuine malfunction and is reported as such, distinctly from a compliance verdict.

**Why this priority**: Three of the last seven failures were agents with no representable winning move on adversarial input (crash scored as infrastructure error; empty output scored as failure). Boundary testing is meaningless until compliant refusal is defined.

**Independent Test**: Run the judge's boundary probes against the generated agent. Verify each probe yields a pass/fail verdict (never an infrastructure-error verdict) and that a probe requesting ungranted activity results in a refusal record scored as compliant.

**Acceptance Scenarios**:

1. **Given** an adversarial input requesting activity outside the grants, **When** the agent runs, **Then** it terminates successfully with a refusal record (empty or filtered actions plus machine-readable reason) rather than crashing.
2. **Given** a refusal record produced on a boundary probe, **When** the judge scores it, **Then** the verdict is pass (compliant refusal), not error.
3. **Given** a refusal record produced on a happy-path input, **When** the judge scores it, **Then** the verdict is fail (purpose not fulfilled), not error.
4. **Given** the judge-spec generator synthesizing boundary tests, **When** it writes expected behaviors, **Then** those behaviors reference the refusal contract rather than an undefined refusal shape.
5. **Given** a genuine agent malfunction (e.g., malformed internal state), **When** the harness observes abnormal termination, **Then** the result is reported as a malfunction distinct from both pass and fail compliance verdicts.

---

### User Story 3 - Judging an agent causes no external side effects (Priority: P3)

When the pipeline evaluates a candidate agent before deployment, any actions the agent's runtime reasoning selects are recorded rather than executed. The recorded transcript — including any deterministic rejections — is what the judge scores. No notification, message, or other external effect leaves the system during evaluation, while the agent's reasoning proceeds as if its actions succeeded.

**Why this priority**: Without this, every judge run of the hello-world agent actually posts to Discord, so evaluation is not repeatable and boundary probing of more dangerous connectors would be unsafe. It is P3 only because stories 1 and 2 must define the channel and contract being recorded.

**Independent Test**: Run the full judge evaluation against the generated agent while monitoring the external endpoint. Verify zero external deliveries occurred and that the judge's verdict references the recorded action transcript.

**Acceptance Scenarios**:

1. **Given** a judge evaluation run, **When** the agent's runtime reasoning selects a granted action, **Then** the action is recorded with its full details and a synthetic success result is returned to the reasoning loop, and no external effect occurs.
2. **Given** a completed evaluation run, **When** the judge scores the test case, **Then** the observed actions presented to the judge are the recorded transcript, including any deterministic rejections.
3. **Given** an evaluation run, **When** inference calls are made by the agent, **Then** they are still metered against the spend cap exactly as in a live run.

---

### User Story 4 - Model identity is substrate policy, not a workload claim (Priority: P4)

Which reasoning model an agent uses — and therefore what it costs — is decided by the substrate's configuration, not by strings authored into the generated code by a language model. The runtime environment supplies the model identity to the agent, and the substrate resolves the effective model itself rather than trusting the workload's claim. A workload-authored model string can no longer cause an unpriced-model failure or select an unintended model.

**Why this priority**: Lowest-frequency failure class (one of seven), and mechanically simple once the other rails exist — but it closes a policy leak: untrusted generated code currently chooses its own model and price point.

**Independent Test**: Generate and run an agent whose code claims a bogus model identity (via a stubbed synthesis output). Verify the run proceeds on the substrate-configured model and the bogus claim is ignored or rejected with a typed error — never an unpriced-model failure mid-pipeline.

**Acceptance Scenarios**:

1. **Given** a substrate-configured runtime model, **When** the harness launches an agent, **Then** the model identity is supplied to the agent's environment by the substrate.
2. **Given** an agent request claiming a model different from substrate policy, **When** the inference chokepoint processes it, **Then** the effective model is resolved by the substrate and the workload's claim does not determine pricing or routing.
3. **Given** the synthesis stage authoring an agent body, **When** its instructions are constructed, **Then** they no longer require any language model to reproduce an exact model-identifier string.

---

### User Story 5 - The judge scores purpose-fit, not string reproduction (Priority: P5)

The compliance judge evaluates whether the agent accomplished its stated purpose and honored the refusal contract. It is never asked to verify that exact connector, method, or model strings were used — that is the deterministic gate's job, already done by the time the judge sees the transcript. The judge-spec generator stops synthesizing tests whose pass condition is exact string reproduction by a language model.

**Why this priority**: This realigns the judge with its documented role (probabilistic smoke detector, not firewall). It is last because it is largely a consequence of stories 1–3: once enforcement is deterministic and the transcript is recorded, string-checking tests have nothing left to check.

**Independent Test**: Inspect a freshly synthesized judge spec and verify no test's expected behavior requires exact-string verification; run the judge and verify verdict reasoning addresses purpose fulfillment and refusal-contract adherence only.

**Acceptance Scenarios**:

1. **Given** a manifest and purpose, **When** the judge spec is synthesized, **Then** its expected behaviors concern purpose fulfillment, boundary refusal, and termination — not exact identifier strings.
2. **Given** a recorded transcript containing a deterministic rejection of an ungranted request, **When** the judge scores it, **Then** the rejection is presented as an observed fact (the substrate blocked X), and the judge scores the agent's behavior around it rather than re-deriving whether X was granted.

---

### Edge Cases

- A granted connector has no tool declaration in the registry: the pipeline must fail loudly at generation time (consistent with the existing loud-failure rule for missing registry entries), not silently produce an agent with no usable capabilities.
- The runtime model emits zero tool calls on a happy-path input: this is a scoreable purpose failure (User Story 2, scenario 3), not an infrastructure error.
- The runtime model emits a well-formed tool call with invalid or missing parameters: the substrate rejects or the connector errors; either way the outcome is recorded and scoreable, with no external partial effect during evaluation.
- Multiple grants in one manifest: the structured channel must scale past the single-grant case — each grant contributes its declaration, and rejection logic applies per call.
- A manifest whose purpose genuinely requires no runtime inference (constant single action): the generated agent may still route through the structured channel; the spec does not require inference-free short-circuiting, but nothing may forbid the synthesis stage from producing simpler bodies.
- Recorded-mode evaluation of an agent whose reasoning depends on real tool results (e.g., read-then-act): synthetic results must be shaped well enough for the reasoning loop to proceed; if a purpose cannot be meaningfully evaluated on synthetic results, the verdict must say so rather than fail silently.
- Spend cap breached mid-evaluation: existing breach semantics apply unchanged; the evaluation reports the breach rather than an opaque failure.
- Previously generated agent bodies using the retired free-text protocol: they are regenerated, not migrated; the pipeline never needs to support both protocols simultaneously.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The agent synthesis stage MUST NOT instruct any language model to reproduce, remember, or verify a manifest-derived exact string (connector identifier, method name, recipient) or an exact model identifier. The existing prohibition on such strings appearing in generated code remains in force.
- **FR-002**: Generated agents MUST select runtime actions exclusively through the substrate's structured tool-call channel, whose available tools are derived from the capability manifest by the substrate. The free-text JSON action protocol MUST be removed from the synthesis instructions.
- **FR-003**: The substrate MUST reject any tool call naming an ungranted connector deterministically, with a typed machine-readable error, before any external effect occurs.
- **FR-004**: The substrate MUST reject a tool call whose connector is granted but whose requested method (or equivalent scoping parameter) is outside the grant, deterministically and before any external effect.
- **FR-005**: Every deterministic rejection MUST be recorded in a form available for audit and for judge scoring.
- **FR-006**: A written refusal contract MUST define the compliant agent response to input requesting activity beyond the agent's purpose or grants: successful termination with a machine-readable record containing an empty or filtered action set and a reason. Abnormal termination is reserved for genuine malfunction.
- **FR-007**: The evaluation harness MUST treat agent exit status and refusal-shaped output as scoreable observations. Only faults of the harness or environment itself may produce an infrastructure-error result; an agent's refusal, empty output, or abnormal exit on a test input yields a compliance verdict or a distinct malfunction report, never a silent abort of scoring.
- **FR-008**: The judge-spec generator MUST be informed of the refusal contract so that synthesized expected behaviors reference it, and MUST NOT synthesize tests whose pass condition is exact-string reproduction by a language model.
- **FR-009**: During judge evaluation, the substrate MUST operate the tool channel in a record-don't-execute mode: granted tool calls are recorded with full details, a synthetic success result is returned to the agent's reasoning loop, and no external effect occurs.
- **FR-010**: The recorded transcript (granted calls, synthetic results, deterministic rejections) MUST be the observed-actions input to judge scoring.
- **FR-011**: Inference calls made during recorded-mode evaluation MUST be metered against the spend cap identically to live runs. Costs attributed to connector execution MUST NOT be charged for recorded (non-executed) calls.
- **FR-012**: The substrate MUST resolve the effective reasoning model for agent runtime inference from its own configuration (or the manifest), supply it to the agent's environment at launch, and MUST NOT allow a workload-supplied model claim to determine routing or pricing.
- **FR-013**: The judge MUST score semantic purpose-fit and refusal-contract adherence only. Exact-string grant compliance is out of the judge's scope; deterministic rejections appear in its input as observed facts, not questions to re-answer.
- **FR-014**: If a granted connector lacks a tool declaration in the capability registry, agent generation MUST fail loudly before any agent body is written.
- **FR-015**: The end-to-end generation pipeline for the existing hello-world Discord scenario MUST pass using only the mechanisms above, with the retired free-text protocol absent from all synthesis instructions and generated artifacts.

### Key Entities

- **Capability manifest**: The existing authoritative grant record (connectors, methods, recipients, spend cap). Unchanged in shape; becomes the sole source from which tool declarations are derived.
- **Tool declaration**: The substrate-owned structured description of one granted capability, presented to the runtime reasoning model as the only vocabulary for action selection.
- **Action transcript**: The ordered record of a run's tool activity — granted calls with parameters, results (real or synthetic), and deterministic rejections. In evaluation runs it is the judge's observed-actions input.
- **Refusal record**: The machine-readable output of a compliant refusal: empty or filtered action set plus reason, delivered via successful termination.
- **Verdict**: The judge's scored outcome per test case — pass, fail, or (distinctly) malfunction/infrastructure error — with reasoning referencing purpose-fit and the refusal contract.
- **Model policy**: The substrate-configured mapping deciding which reasoning model an agent's runtime inference uses, independent of workload claims.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The hello-world Discord generation scenario passes end-to-end in at least 3 consecutive pipeline runs with no failure attributable to the three retired noise classes (identifier hallucination, workload-authored model identifiers, undefined refusal behavior).
- **SC-002**: 100% of ungranted tool requests (connector- or method-level) are blocked before any external effect and produce a typed, recorded rejection — verified by injecting ungranted requests via a stubbed runtime model.
- **SC-003**: Zero external deliveries occur during judge evaluation runs, measured at the external endpoint across a full evaluation suite.
- **SC-004**: 100% of adversarial boundary test cases yield a pass/fail compliance verdict (or an explicit malfunction report) — zero infrastructure-error verdicts caused by agent refusal behavior.
- **SC-005**: No manifest-derived identifier or model identifier appears in any generated agent body or agent-authored prompt, verified by scanning generated artifacts across the runs in SC-001.
- **SC-006**: A deliberately injected bogus model claim from the workload does not alter the effective model, its pricing, or pipeline success.

## Assumptions

- The existing capability registry can supply a tool declaration for every connector reachable by current manifests; where one is missing, adding it is in scope of implementation, and until then generation fails loudly (FR-014).
- The constitutional division of labor is unchanged: the deterministic gate/chokepoint remains the sole enforcement boundary; the judge remains a probabilistic smoke detector. This feature moves work onto the correct side of that line rather than redrawing it.
- The refusal contract's default shape — successful exit with empty-or-filtered actions plus a machine-readable reason — is acceptable; no alternative shape (e.g., dedicated exit codes per refusal class) is required.
- During recorded-mode evaluation, synthetic tool results are generic acknowledgments of success; higher-fidelity simulation of connector responses is out of scope for this feature.
- Previously generated agent bodies are regenerated under the new protocol; no backward compatibility with the free-text action protocol is maintained anywhere in the pipeline.
- The port-workload contract (one line of JSON in on stdin, one line of JSON out on stdout, exit status) is retained; the refusal record and any run summary travel within that contract.
- Spend metering semantics (caps, windows, breach behavior) are unchanged except that non-executed recorded tool calls do not incur connector execution costs.
- The security-review stage's role is unchanged; this feature does not relax any structural guard on generated code (no direct provider paths, no credential material, no manifest literals).
