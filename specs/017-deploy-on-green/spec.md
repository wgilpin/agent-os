# Feature Specification: Stage 6 Deploy-on-Green

**Feature Branch**: `017-deploy-on-green`
**Created**: 2026-07-01
**Status**: Draft
**Input**: User description: "Stage 6 deploy-on-green — the final wiring step of the v3 generation pipeline: gate an agent's deployment on a joint pass from BOTH the co-generated judge (013/stage 3, code-matches-manifest) AND the Stage 5 security-review agent (016-security-review, smoke-detector verdict), then hand the deploy decision to the existing review-mode rail (011-review-modes-envelope: --always-review | --review-if-risky | --dangerously-skip-review). \"Green\" means judge verdict = pass AND security-review verdict = pass; if either is a fail, deployment does not proceed regardless of review mode, and the failure is recorded in the standing inventory with which check failed. On green, the review-mode rail governs whether a human blocks the deploy or it proceeds automatically (skipped-in-envelope / dangerously-skipped), exactly as 011 already specifies — 04-09 does not change review-mode semantics, it supplies the judge+security-review precondition that must hold before that rail is even consulted. Re-verify, for this specific case, that the manifest-not-readable-by-agent invariant (proven in Phase 3 world-B) still holds when the manifest itself was machine-written by Stage 2 (013-write-manifest) rather than hand-authored — the generated agent must not be able to read or reason over its own manifest at runtime, and the runtime gate must still enforce it as an external, deterministic predicate. Record provenance and both verdicts (judge, security-review) together in the standing inventory. This is glue/gating logic only: no new judge or security-review logic, no changes to the envelope predicate math from 011 — REQ-deploy-on-green."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Both Checks Pass, Deploy Proceeds Under Review Mode (Priority: P1)

An administrator (or the automated post-conversation pipeline) attempts to deploy a newly generated agent. Both the co-generated judge and the Stage 5 security-review agent have returned a pass verdict for this agent's code+manifest+purpose. The deployment decision is handed to the existing review-mode rail (011), which governs whether a human must approve or the deploy proceeds automatically, exactly as 011 already specifies.

**Why this priority**: This is the core "green path" the whole pipeline exists to automate — without it, generation stops at Stage 5 and nothing ever deploys.

**Independent Test**: Provide a judge verdict = pass and a security-review verdict = pass for a test agent, run deploy-on-green under each of the three review modes, and confirm the review-mode rail's existing behavior (block-and-wait, auto-deploy-in-envelope, or dangerously-skip) is invoked unchanged, with both verdicts and the resulting provenance recorded together in the standing inventory.

**Acceptance Scenarios**:

1. **Given** a judge verdict of pass and a security-review verdict of pass, **When** deployment is attempted under `--always-review`, **Then** the deploy blocks on human approval exactly as 011 specifies, and the standing inventory shows both verdicts as pass once approved.
2. **Given** a judge verdict of pass and a security-review verdict of pass for a manifest within the envelope, **When** deployment is attempted under `--review-if-risky`, **Then** the deploy proceeds automatically with provenance `skipped-in-envelope`, and both verdicts are recorded alongside it.
3. **Given** a judge verdict of pass and a security-review verdict of pass, **When** deployment is attempted under `--dangerously-skip-review`, **Then** the deploy proceeds immediately with provenance `dangerously-skipped`, and both verdicts are recorded alongside it.

---

### User Story 2 - Either Check Fails, Deploy Is Blocked Regardless of Review Mode (Priority: P1)

An administrator attempts to deploy an agent where the judge verdict is a fail, or the security-review verdict is a fail, or both. The deploy-on-green gate refuses to proceed to the review-mode rail at all — this holds under every review mode, including `--dangerously-skip-review`, because "green" is a precondition to review mode being consulted, not something review mode can override.

**Why this priority**: This is the safety property the whole stage exists for — a red verdict must never be deployable by choosing a more permissive review mode.

**Independent Test**: Provide a fail verdict from the judge only, a fail verdict from security-review only, and fail verdicts from both, and attempt deployment under all three review modes (including `--dangerously-skip-review`). Confirm deployment never proceeds in any of the nine combinations, and the standing inventory records which check(s) failed.

**Acceptance Scenarios**:

1. **Given** a judge verdict of fail and a security-review verdict of pass, **When** deployment is attempted under any review mode, **Then** deployment does not proceed and the standing inventory records the judge check as the failing check.
2. **Given** a judge verdict of pass and a security-review verdict of fail, **When** deployment is attempted under any review mode, **Then** deployment does not proceed and the standing inventory records the security-review check as the failing check.
3. **Given** a judge verdict of fail and a security-review verdict of fail, **When** deployment is attempted under `--dangerously-skip-review`, **Then** deployment still does not proceed, demonstrating that no review mode is permission to bypass the judge+security-review precondition.

---

### User Story 3 - Manifest Invisibility Holds for a Machine-Written Manifest (Priority: P2)

A security auditor re-verifies, specifically for agents produced by the generation pipeline, that the deployed agent cannot read or reason over its own manifest at runtime, and that the runtime gate enforces that machine-written manifest as an external, deterministic predicate — the same invariant proven for hand-written manifests in Phase 3 (world-B verification), now confirmed to hold when Stage 2 (013-write-manifest) wrote the manifest instead of a human.

**Why this priority**: This is the headline safety claim of Phase 4 — enforcement must hold "regardless of code (and now manifest) the OS wrote itself." It is a re-verification, not new enforcement logic, so it is P2 relative to the deploy gating itself.

**Independent Test**: Deploy a generated agent (machine-written manifest + machine-written code) that passed both judge and security-review, then run the existing world-B verification suite's manifest-invisibility checks against it and confirm they pass identically to the hand-written-manifest case.

**Acceptance Scenarios**:

1. **Given** a deployed agent whose manifest was machine-written by Stage 2, **When** the agent's own code attempts to read or introspect its manifest at runtime, **Then** the attempt is denied or the manifest is inaccessible, identically to the hand-written-manifest case.
2. **Given** a deployed agent with a machine-written manifest, **When** the agent proposes an action outside its granted capabilities, **Then** the runtime gate blocks the action as a deterministic external predicate, independent of how the manifest was authored.

---

### Edge Cases

- What happens when a verdict is missing entirely (e.g., the judge or security-review stage was never run for this agent)? Deploy-on-green treats a missing verdict as a fail — deployment does not proceed, and the inventory records "no verdict" as the failing reason.
- How does the system handle a re-deploy attempt after a prior fail has been fixed and re-reviewed? Deploy-on-green re-evaluates the current verdicts at deploy time; a fresh pass on both checks allows the deploy to proceed under the active review mode.
- What happens if the judge and security-review verdicts come from different versions of the generated code (e.g., code was regenerated after the judge ran but before security-review)? Deploy-on-green MUST verify both verdicts pertain to the same code artifact; a mismatch is treated as a fail with a distinct "stale verdict" reason recorded in the inventory.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST evaluate a "green" gate for every deployment attempt of a generated agent, defined as judge verdict = pass AND security-review verdict = pass, both for the same code artifact being deployed.
- **FR-002**: The system MUST NOT proceed to the review-mode rail (011) — under any of the three review modes — unless the green gate evaluates true.
- **FR-003**: When the green gate evaluates false, the system MUST record in the standing inventory which check(s) failed (judge, security-review, both, or missing/stale verdict), and MUST NOT deploy the agent.
- **FR-004**: When the green gate evaluates true, the system MUST hand the deploy decision to the existing review-mode rail (011) unchanged — deploy-on-green MUST NOT alter the envelope predicate, the review-mode selection logic, or the provenance values (`reviewed=human`, `skipped-in-envelope`, `dangerously-skipped`) defined by 011.
- **FR-005**: The system MUST record both the judge verdict and the security-review verdict together with the resulting deploy provenance in the standing inventory for every deployment attempt (successful or blocked).
- **FR-006**: The system MUST treat a missing verdict (judge or security-review never run for this agent) as equivalent to a fail for gating purposes.
- **FR-007**: The system MUST verify that the judge verdict and the security-review verdict apply to the same version of the generated code artifact being deployed; a mismatch MUST be treated as a fail with a distinct reason recorded.
- **FR-008**: For agents whose manifest was machine-written (Stage 2 / 013-write-manifest), the runtime gate MUST enforce the manifest as an external, deterministic predicate, and the deployed agent's own code MUST NOT be able to read or reason over its own manifest at runtime — matching the invariant already proven for hand-written manifests in Phase 3 world-B verification.
- **FR-009**: The system MUST NOT introduce any new judge logic or security-review logic as part of this feature — it consumes existing verdicts from 013/014 (judge) and 016 (security-review) as inputs.
- **FR-010**: The system MUST NOT modify the envelope predicate math or review-mode semantics defined in 011-review-modes-envelope.

### Key Entities *(include if feature involves data)*

- **Deploy-on-Green Decision**: The gating record for one deployment attempt — references the judge verdict, the security-review verdict, the code artifact version they each apply to, the resulting green/not-green outcome, the failing reason(s) if not green, and (when green) the provenance produced by the review-mode rail.
- **Judge Verdict**: Existing pass/fail result from the co-generated judge (013/014), consumed but not produced by this feature.
- **Security-Review Verdict**: Existing pass/fail smoke-detector result from the Stage 5 security-review agent (016), consumed but not produced by this feature.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of deployment attempts where either the judge or the security-review verdict is a fail are blocked from deploying, across all three review modes, with zero exceptions.
- **SC-002**: 100% of deployment attempts where both verdicts are pass are handed to the review-mode rail with its existing, unmodified behavior — verified by the review-mode rail's own acceptance scenarios continuing to pass unchanged when invoked through deploy-on-green.
- **SC-003**: Every deployment attempt (blocked or successful) has both verdicts and the outcome/provenance visible together in the standing inventory, viewable without asking the agent.
- **SC-004**: The manifest-invisibility and runtime-gate-enforcement checks from the Phase 3 world-B verification suite pass at the same rate (100%) when re-run against a generated agent with a machine-written manifest as they do against a hand-written manifest.

## Assumptions

- The co-generated judge (013-write-manifest / 014-write-judge) and the Stage 5 security-review agent (016-security-review) already produce a queryable pass/fail verdict per agent, as established by their respective specs; this feature only reads those verdicts.
- The review-mode rail (011-review-modes-envelope) already implements the three modes and the deterministic envelope predicate; this feature only gates entry into that rail and does not alter it.
- "Same code artifact" is identified by whatever versioning/hash mechanism the judge and security-review stages already use to reference the generated `main.py`/`models.py`; this feature does not introduce a new versioning scheme, only a comparison at gate time.
- The Phase 3 world-B verification suite (008-world-b-verification) already contains the manifest-invisibility and runtime-gate acceptance tests; this feature re-runs them against generated output rather than redefining them.
- This feature is glue/gating logic in the deploy path (likely near the existing provisioning/deploy code path in the Elixir substrate) — it introduces no new user-facing surface beyond the standing inventory fields for verdicts and failing reasons.
