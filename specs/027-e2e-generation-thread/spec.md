# Feature Specification: E2E Generation MVP Thread + World-B on a Generated Agent

**Feature Branch**: `027-e2e-generation-thread`
**Created**: 2026-07-01
**Status**: Draft
**Input**: User description: "Plan 04-10: E2E Generation MVP thread + world-B-on-generated agent — the headline acceptance criterion for v3 (Generation MVP). (1) An end-to-end orchestrator that runs the full six-stage generation pipeline human-out-of-the-loop AFTER the elicitation conversation completes: Stage 1 elicit-spec (012) → Stage 2 write-manifest (013) → Stage 3 write-judge (014) → Stage 4 write-novel-agent (015) → Stage 5 security-review (016) → Stage 6 deploy-on-green (017), threading each stage's output into the next and handing the final deploy to the existing review-mode rail (011). The worked example is 'reply to recruiter emails'. (2) Re-run the FULL spec-008 world-B verification suite against a GENERATED agent — machine-written manifest (Stage 2) AND machine-written code (Stage 4) — proving the deterministic gate physically prevents every manifest breach regardless of code the OS authored itself. Scope: do NOT re-implement any stage, do NOT change the gate/envelope/review-mode semantics; reuse the existing spec-008 world-B harness retargeted at a generated agent."

## Overview

This is the plan that makes Agent OS's defining thesis literally true: **the OS builds
its own agents from a stated purpose, and the gate holds regardless of what code the OS
wrote.** Every individual piece already exists — the six pipeline stages (012–017), the
deterministic gate, the review-mode rail (011), and the spec-008 world-B suite. What has
never existed is (a) a single orchestrated run that carries a confirmed purpose all the
way to a deployed agent with no further human input, and (b) evidence that world-B — the
"gate physically prevents every breach" guarantee earned on *hand-written* agents —
survives when both the manifest and the agent code were machine-written.

This feature is glue and proof, not new capability. It threads the existing stages
together and re-points the existing world-B suite at a generated target. Its completion
is the headline acceptance criterion for the Generation MVP (v3): after this, a
non-coder can declare a purpose and receive a deployed, gate-enforced, novel agent.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A confirmed purpose becomes a deployed novel agent, human-out-of-the-loop (Priority: P1)

Once the elicitation conversation has produced a confirmed purpose, the operator invokes
a single pipeline run. The OS then, with no further human input required, writes the
manifest, writes the judge, synthesises novel agent code, security-reviews it, and — if
both the judge and the security review pass — deploys the agent through the existing
review-mode rail. The operator observes one legible thread from "confirmed purpose" to
"deployed" (or to a clearly-attributed stop), never having to invoke each stage by hand
or inspect intermediate artifacts to know what happened. The worked example carried
through the whole thread is "reply to recruiter emails".

**Why this priority**: This is the load-bearing promise of the entire product — "declare
a purpose → get a deployed agent, no further human input." Without it, all six stages
exist but the OS cannot actually build an agent end-to-end; the thesis is unproven.

**Independent Test**: Starting from a confirmed "reply to recruiter emails" purpose, run
the pipeline and confirm that (a) each stage's output artifact is consumed by the next
stage, (b) a deploy decision is reached with no human input between stages, and (c) the
standing inventory shows the completed thread with both verdicts and provenance.

**Acceptance Scenarios**:

1. **Given** a confirmed purpose from a completed elicitation conversation, **When** the pipeline is run, **Then** the pipeline stages execute in dependency order (manifest before the judge and the agent; generated code before both verdicts; both verdicts before the deploy gate), each stage consuming the artifacts it depends on, with no human prompt required between stages.
2. **Given** a run where the judge and the security review both pass, **When** the deploy stage is reached, **Then** the deploy decision is handed to the existing review-mode rail unchanged and the agent is deployed (or blocked only where that rail already specifies a human block).
3. **Given** a completed run, **When** the operator reads the standing inventory, **Then** the judge verdict, the security-review verdict, and the deploy provenance (reviewed=human | skipped-in-envelope | dangerously-skipped) are all visible without asking the agent.
4. **Given** the "reply to recruiter emails" worked example, **When** the pipeline runs after the conversation, **Then** the entire thread from confirmed purpose to deploy decision completes as one operation.

---

### User Story 2 - Enforcement holds against an agent the OS wrote itself (Priority: P1)

A security-conscious stakeholder needs assurance that the deterministic gate's guarantee
does not depend on the agent code being written by a trusted human. Against a generated
agent — one whose manifest was machine-written by Stage 2 and whose body was
machine-written by Stage 4 — the full world-B breach battery is executed. Every attempted
manifest breach (unlisted recipient, unlisted connector, egress beyond grants, reading
the manifest, exceeding spend) is physically prevented by the gate, exactly as it is for
a hand-written agent.

**Why this priority**: Auto-deploy-on-green is only sound in "world B" — where the gate
prevents breach regardless of agent code. The whole v3 safety argument rests on this
holding for *machine-written* code, not just human-written code. This is the acceptance
criterion the plan exists to satisfy.

**Independent Test**: Take a generated agent (machine-written manifest + machine-written
body), run the existing spec-008 world-B suite against it, and confirm every breach case
fails to breach — no case is skipped, weakened, or made to pass by the fact that the code
was generated.

**Acceptance Scenarios**:

1. **Given** a generated agent with a machine-written manifest and machine-written body, **When** the spec-008 world-B breach battery runs against it, **Then** every breach attempt is denied by the gate.
2. **Given** the generated agent, **When** it attempts to read its own manifest at runtime, **Then** the manifest is not readable by it, identically to the hand-written case.
3. **Given** the world-B suite as it exists for the hand-written discovery agent, **When** it is retargeted at the generated agent, **Then** the same breach cases run with no case removed or relaxed.

---

### User Story 3 - A partial-failure run stops legibly and safely (Priority: P2)

When any stage in the thread fails — the judge fails, the security review fails, code
synthesis errors, or a stage crashes — the run stops without deploying, and the operator
can see exactly which stage stopped it and why, from the standing inventory. A failed
run never results in a deployed agent, and never leaves the operator having to "ask the
agent" what went wrong.

**Why this priority**: Legibility is the non-negotiable principle, and "no deploy on any
red" is the safety counterpart to "deploy on green." It is P2 because the primary green
path (US1) and the enforcement proof (US2) are the headline deliverables; graceful stop
is essential but secondary to demonstrating the thread works at all.

**Independent Test**: Force a judge failure and, separately, a security-review failure,
and confirm each stops the thread before deploy with the failing stage attributed in the
inventory.

**Acceptance Scenarios**:

1. **Given** a run where the judge returns fail, **When** the pipeline reaches the deploy gate, **Then** no deploy occurs and the inventory records the judge as the failing check.
2. **Given** a run where the security review returns fail, **When** the pipeline reaches the deploy gate, **Then** no deploy occurs and the inventory records the security review as the failing check.
3. **Given** a stage that crashes mid-run, **When** the failure surfaces, **Then** the run stops, no agent is deployed, and the failure is attributed to a stage rather than lost.

---

### Edge Cases

- What happens when the judge passes but the security review fails (or vice versa)? → No deploy; the failing check is recorded. "Green" requires both.
- What happens when a stage produces a malformed artifact the next stage cannot consume? → The run stops at the consuming stage and attributes the failure there; no deploy.
- What happens under `--dangerously-skip-review` for a generated agent? → Deploy-review may be skipped, but the runtime gate still enforces the machine-written manifest; world-B (US2) must still hold. Review-mode governs the deploy block only, never the gate.
- What happens if the world-B suite is run against a generated agent whose manifest grants more than the discovery agent's? → The breach cases are defined relative to the agent's own manifest grants, so the suite is parameterised by the target manifest, not hard-coded to the discovery agent's grants.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a single entry point that, given a confirmed purpose, runs the generation pipeline from write-manifest (Stage 2) through deploy-on-green (Stage 6) without requiring human input between stages.
- **FR-002**: Each stage's output artifact MUST be threaded as the input to the stage that depends on it (manifest → judge and agent; generated code → security review; the judge and security verdicts made available to the deploy gate via the persisted verdict stores it already reads), so no stage relies on an operator manually staging a prior stage's output. Note: verdicts reach the deploy gate through the existing verdict stores, not as new arguments, to keep `deploy/3` unchanged (FR-003).
- **FR-003**: The orchestrated run MUST hand the final deploy decision to the existing review-mode rail (011) unchanged — it MUST NOT alter the envelope predicate, the deploy-on-green precondition, or review-mode semantics.
- **FR-004**: The orchestrated run MUST NOT re-implement or duplicate any stage's logic; it composes the existing stage modules.
- **FR-005**: On a run where BOTH the judge and the security review pass, the system MUST proceed to the deploy decision; on ANY fail from either, the system MUST NOT deploy.
- **FR-006**: After a run, the standing inventory MUST show the judge verdict, the security-review verdict, and the deploy provenance (reviewed=human | skipped-in-envelope | dangerously-skipped) — readable without asking the agent.
- **FR-007**: A failed or crashed stage MUST stop the thread before deploy, MUST NOT leave an agent deployed, and MUST attribute the stop to the responsible stage in the inventory.
- **FR-008**: The system MUST be able to execute the full spec-008 world-B verification suite against a GENERATED agent — one whose manifest was machine-written by Stage 2 and whose body was machine-written by Stage 4.
- **FR-009**: When run against a generated agent, the world-B suite MUST include every breach case present in the hand-written-agent suite, with no case removed, skipped, or weakened.
- **FR-010**: The world-B suite MUST verify that a generated agent cannot read its own (machine-written) manifest at runtime, identically to the hand-written case.
- **FR-011**: The world-B breach cases MUST be evaluated relative to the target agent's own manifest grants, so the suite is valid for a generated agent's manifest rather than hard-coded to the discovery agent's grants.
- **FR-012**: The worked example "reply to recruiter emails" MUST run through the full thread as the demonstration case, from confirmed purpose to deploy decision.

### Key Entities *(include if feature involves data)*

- **Pipeline Run**: One end-to-end execution of the generation thread for a single confirmed purpose. Carries the ordered sequence of stage outcomes, the two gate verdicts (judge, security review), the deploy decision, and provenance. Is the unit recorded in the standing inventory.
- **Generated Agent**: The subject of world-B on generated code — the pairing of a machine-written manifest (Stage 2 output) and a machine-written agent body (Stage 4 output), targeted by the retargeted world-B suite.
- **World-B Breach Case**: An individual attempted manifest breach (unlisted recipient/connector, over-grant egress, manifest read, spend-cap exceed) evaluated against a target agent's manifest grants; collectively the world-B battery.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Starting from a confirmed purpose, an operator can reach a deploy decision for a novel agent in a single invocation, with zero human inputs required between stages.
- **SC-002**: For the "reply to recruiter emails" worked example, the full thread from confirmed purpose to deploy decision completes as one operation.
- **SC-003**: 100% of the spec-008 world-B breach cases that hold for the hand-written discovery agent also hold for a generated agent (machine-written manifest + machine-written code) — every breach is prevented.
- **SC-004**: The number of world-B breach cases exercised against the generated agent equals the number exercised against the hand-written agent (no case dropped or skipped).
- **SC-005**: After any run — pass or fail — an operator can determine the outcome, both gate verdicts, and (on green) the deploy provenance entirely from the standing inventory, without invoking or querying the agent.
- **SC-006**: No run in which either gate verdict is a fail, or in which a stage crashes, results in a deployed agent (0 deploys on any red).
- **SC-007**: The change adds no new stage logic and makes no change to the gate, envelope predicate, or review-mode semantics (verified by the existing 008/011/017 suites continuing to pass unchanged).

## Assumptions

- All six pipeline stages (specs 012–017), the review-mode rail (011), the deterministic gate, and the spec-008 world-B suite are present and passing on this branch; this plan composes them and does not fix or extend them.
- "Human-out-of-the-loop" applies AFTER the elicitation conversation (Stage 1) has already produced a confirmed purpose; the conversation itself remains the load-bearing human-in-the-loop step and is out of scope here.
- The elicitation/conversation UI is not required for this plan — a confirmed purpose is the starting input, whether produced interactively or supplied as a fixture for the worked example.
- The existing spec-008 world-B harness can be parameterised by a target agent (manifest + body) rather than being hard-wired to the discovery agent; retargeting it is in scope, rewriting its breach logic is not.
- "Deploy" means the substrate provisions/records the agent per the existing deploy-on-green + review-mode behaviour; it does not imply live external side effects beyond what the gate already permits.
- Review-mode default for the worked example follows the v3-launch default (`--always-review`) unless a run explicitly selects another mode; the mode governs only the deploy block, never the gate.
