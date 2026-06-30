# Feature Specification: Stage 3 Write the Judge (write-judge)

**Feature Branch**: `014-write-judge`  
**Created**: 2026-06-30  
**Status**: Draft  
**Input**: User description: "Stage 3 of the v3 six-stage generation pipeline — WRITE THE JUDGE. Synthesise an eval-lite test suite that certifies CODE-MATCHES-MANIFEST — explicitly NOT manifest-matches-intent (that was Stage 1's job; the human-confirmed manifest from Stage 2 / 04-05 is the safety artifact, the judge is not). This stage does NOT talk to the user, does NOT write the agent body, does NOT run security review, and does NOT deploy; it produces the judge artifact (and its synthesis is recorded for the inventory)."

## Overview

Stage 3 is the third step of the six-stage v3 generation pipeline. It operates after the machine-written manifest has been emitted and confirmed (Stage 2) but **before the agent body code exists** (Stage 4). 

Its primary function is to **write the judge**—an eval-lite, non-deterministic, LLM-based test suite that certifies **CODE-MATCHES-MANIFEST**. It explicitly does *not* certify manifest-matches-intent; that was Stage 1's responsibility. The human-confirmed manifest from Stage 2 is the actual safety artifact; the judge is a pre-deploy smoke detector.

The core challenge of Stage 3 is the **co-generation caveat**: since both the judge and the agent are synthesized by the same system from the same purpose, a misread specification will yield an agent and a test suite that are wrong in the same direction, falsely agreeing with each other. This specification resolves the open question (#rhj7 / design:223) by enforcing **strict independent derivation and information isolation** between the judge and the agent body, ensuring the judge remains an objective evaluator.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Synthesise a test spec from the manifest and purpose (Priority: P1)

Given a machine-written manifest and a confirmed purpose, Stage 3 generates a declarative test specification (`judge_spec.json`). This specification defines test inputs (triggers, incoming messages), expected behaviors, and tailored evaluation prompts for the LLM-as-judge, serving as the target the Stage 4 agent must satisfy.

**Why this priority**: P1. This is the core delivery of Stage 3. Without this test specification, there is no contract target for the agent to satisfy and no evaluation criteria for deploy-time.

**Independent Test**: Provide a mock manifest and purpose to Stage 3. Verify that it writes a valid `judge_spec.json` containing test cases covering the manifest's purpose, capabilities, and boundaries, without calling the agent or expecting it to exist.

**Acceptance Scenarios**:

1. **Given** a confirmed manifest with capabilities `{gmail_read, gmail_send}` and a purpose, **When** Stage 3 runs, **Then** it produces a `judge_spec.json` containing test cases that exercise both reading and sending capabilities.
2. **Given** the generated `judge_spec.json`, **When** validated, **Then** it conforms to a structured JSON schema including keys for `tests`, `input`, `expected_behavior`, and `eval_prompt`.

---

### User Story 2 - Resolve the co-generation caveat via independent derivation (Priority: P1)

To prevent a misread specification from making both the agent and the judge wrong in the same direction, Stage 3 is strictly isolated. The judge generator cannot see Stage 1's conversation transcript, and the Stage 4 Agent Generator cannot see the generated `judge_spec.json`. They share only the manifest and purpose contract.

**Why this priority**: P1. This is the headline risk identified in the design doc (:116, :223). Without this isolation, co-generation makes the tests ineffective at catching spec misreads.

**Independent Test**: Verify that the Stage 3 generation process has no programmatic access to Stage 1's chat/elicitation transcript. Confirm that the Stage 4 agent generation toolchain does not load or reference `judge_spec.json` when generating the agent.

**Acceptance Scenarios**:

1. **Given** Stage 3 is invoked, **When** its input parameters and context are inspected, **Then** only the confirmed `purpose` string and the `Manifest` struct are available; Stage 1 elicitation logs are absent.
2. **Given** Stage 4 is invoked to generate the agent body, **When** its context is inspected, **Then** it has no access to the `judge_spec.json` produced by Stage 3.

---

### User Story 3 - LLM-as-judge scoring with honest scoping (Priority: P1)

At deploy-time (Stage 6), the judge runner executes the test suite. It feeds inputs to the generated agent, captures the outputs/actions, and uses the `InferenceBroker` to score whether they match the manifest's grants. The verdict must be honestly scoped: it certifies "code matches manifest," not "manifest matches user intent," and explicitly includes this disclaimer.

**Why this priority**: P1. The judge must never claim intent-level correctness (:106) and must fail safe on failures.

**Independent Test**: Execute the judge runner against two mock agents: one that complies with the manifest and one that violates it (e.g. tries to access an ungranted connector). Verify that the runner scores them correctly, prints the disclaimer, and fails on violation.

**Acceptance Scenarios**:

1. **Given** a mock agent that obeys the manifest, **When** the judge runner executes, **Then** it returns `{:ok, :pass}` and prints the disclaimer.
2. **Given** a mock agent that attempts an ungranted action (e.g., egressing to an unallowlisted domain), **When** the judge runner executes, **Then** it returns `{:ok, :fail}`.
3. **Given** the judge's final text report, **When** rendered, **Then** it contains the disclaimer: "Scope: CODE-MATCHES-MANIFEST. This does not verify human intent correctness."

---

### User Story 4 - Route through the single inference chokepoint (Priority: P1)

Every LLM call made by Stage 3 (to generate the test spec) and during deploy-time evaluation (the LLM-as-judge) must route through `AgentOS.InferenceBroker`. No second provider path is introduced, and no direct model credentials exist within the agent or judge directories.

**Why this priority**: P1. Enforces DEC-remove-llm-from-credential-boundary and the single inference chokepoint.

**Independent Test**: Assert that all model calls made during Stage 3 execution are metered by the `InferenceBroker` and charged against the run token.

**Acceptance Scenarios**:

1. **Given** Stage 3 is running, **When** a model call is made, **Then** it invokes `AgentOS.InferenceBroker.complete/2` with the appropriate run token.
2. **Given** the agent has no direct model credentials, **When** the judge runner makes an LLM-as-judge call, **Then** it routes through `AgentOS.InferenceBroker` on the substrate side.

---

### User Story 5 - Render judge results in the standing inventory (Priority: P2)

The standing inventory is updated to display the judge's status (`pass`, `fail`, or `unrun`) along with a timestamp, ensuring complete legibility of the generation pipeline's progress.

**Why this priority**: P2. Surfacing pipeline state in the inventory satisfies REQ-list-inventory.

**Independent Test**: Render the inventory before and after running the judge, and verify the `JUDGE` line updates correctly.

**Acceptance Scenarios**:

1. **Given** an agent is newly generated, **When** `AgentOS.Inventory.render/1` is called, **Then** the output contains `JUDGE: unrun`.
2. **Given** the judge runner has executed and passed, **When** `AgentOS.Inventory.render/1` is called, **Then** the output contains `JUDGE: pass` with the execution timestamp.

---

### Edge Cases

- **Invalid or empty manifest**: Stage 3 halts immediately with an error and writes no test spec.
- **Inference broker timeout/failure during evaluation**: The judge runner fails safe, returning a `:fail` or `:error` status, preventing auto-deployment.
- **Agent exceeds spend cap during judge execution**: The `InferenceBroker` blocks further calls, the run is terminated, and the judge returns `:fail`.
- **Manifest contains no grant-bearing capabilities**: Stage 3 generates a minimal smoke-test suite verifying the agent initiates and exits cleanly without trying to perform any actions.

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Stage 3 MUST accept exactly two inputs: the machine-written `Manifest` struct (or YAML file) from Stage 2 and the confirmed `purpose` string. It MUST NOT read the Stage 1 elicitation transcript.
- **FR-002**: Stage 3 MUST output a declarative test specification file named `judge_spec.json` located under the agent's workspace directory (e.g., `agents/<agent_name>/`).
- **FR-003**: The generated `judge_spec.json` MUST contain structured test cases, where each case defines `input` (trigger/message), `expected_behavior` description, and a tailored `eval_prompt` for LLM-as-judge scoring.
- **FR-004**: Stage 3 MUST NOT expose `judge_spec.json` or its contents to the Stage 4 Agent Generator.
- **FR-005**: All model calls made during Stage 3 (synthesis) and Stage 6 (evaluation) MUST route through `AgentOS.InferenceBroker.complete/2` using the metered run-token.
- **FR-006**: The judge evaluation prompt and final output MUST be honestly scoped: they MUST certify only "code matches manifest" and MUST NOT claim to certify "manifest matches human intent."
- **FR-007**: The final test report and the inventory render MUST include the disclaimer: `"Scope: CODE-MATCHES-MANIFEST. This does not verify human intent correctness."`
- **FR-008**: The judge's status (`:unrun | :pass | :fail`) and the last-run timestamp MUST be persisted in the substrate state store (`AgentOS.StateStore`) under a dedicated collection (e.g., `"judge_results"`).
- **FR-009**: `AgentOS.Inventory.render/1` MUST extract and display the judge result status and last run timestamp.
- **FR-010**: The judge MUST act as a pre-deploy smoke detector and MUST NOT act as the runtime firewall. The deterministic gate remains the sole authority; the judge confers no permission to cross it.
- **FR-011**: The judge runner MUST fail safe (return a fail/error status) if any network, API, or model call fails during evaluation.
- **FR-012**: Stage 3 MUST NOT write the agent body (Stage 4), run security review (Stage 5), or handle deployment/runtime gates (Stage 6).

### Key Entities

- **Manifest (input)**: The machine-written, human-confirmed manifest from Stage 2 defining purpose, grants, spend, owner, and supervision.
- **Purpose (input)**: The raw confirmed purpose string.
- **Judge Specification (`judge_spec.json` output)**: A declarative JSON file containing synthesized test cases and LLM-as-judge evaluation instructions.
- **InferenceBroker**: The substrate-side inference chokepoint through which all model calls route.
- **Judge Result Store**: Substrate state database tracking `:unrun | :pass | :fail` and metadata.

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of generated `judge_spec.json` files parse as valid JSON and contain the required structured keys (`tests`, `input`, `expected_behavior`, `eval_prompt`).
- **SC-002**: The Stage 4 Agent Generator is verified to have 0% access to `judge_spec.json` contents during its code generation phase.
- **SC-003**: Stage 3 synthesis consumes exactly 0 lines of the Stage 1 elicitation transcript.
- **SC-004**: 100% of model calls made during synthesis and evaluation route through `AgentOS.InferenceBroker.complete/2`.
- **SC-005**: `AgentOS.Inventory.render/1` output correctly formats and displays the judge's status and disclaimer.
- **SC-006**: A conforming mock agent passes the judge tests, while a non-conforming mock agent fails them (100% classification accuracy on mock runs).
- **SC-007**: Any API timeout, network error, or broker spend breach during evaluation results in a fail-safe `:fail` verdict.

---

## Assumptions

- **Agent environment**: The agent runs in a sandboxed container/port runner with mock capability connectors. The judge runner can capture and mock the agent's port inputs and outputs.
- **Inference pricing**: The LLM calls made during judge runs are priced and metered under the agent's run token, utilizing the existing model pricing table in `AgentOS.InferencePrice`.
- **No user interaction**: Stage 3 has no conversational surface and runs human-out-of-the-loop.

---

## Out of Scope

- Stage 1 (elicitation), Stage 2 (manifest emission), Stage 4 (agent generation), Stage 5 (security review), Stage 6 (deploy/gate).
- Modifying the deterministic runtime gate or the manifest schema.
- Specifying upstream API provider credentials or choice of model transport.

---

## References

- Roadmap plan 04-06 (Phase 4 Generation MVP) — `.planning/ROADMAP.md`
- REQ-write-judge (#rhj7) — `.planning/REQUIREMENTS.md:65`
- Design doc `agent-os-design.md`: :106 (Stage 3 / judge scoping), :116 (co-generation caveat), :202 (probabilistic components, not a firewall), :223 (judge-co-generation open question), :141 (confers no authority).
- Constitution I, III, X, XI, XII.
