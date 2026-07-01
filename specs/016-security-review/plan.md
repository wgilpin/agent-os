# Implementation Plan: Stage 5 Security Review Agent (04-08)

**Branch**: `016-security-review` | **Date**: 2026-07-01 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/016-security-review/spec.md)
**Input**: Feature specification from `/specs/016-security-review/spec.md`

## Summary

The Stage 5 Security Review Agent is a probabilistic "smoke detector" code auditor. It takes a generated Python agent body (`main.py` + `models.py`), its manifest, and its purpose, wraps them in strict XML boundaries to mitigate prompt injection, and executes an LLM review via the InferenceBroker using a metered run token. The result is stored as a verdict struct in a single-writer StateStore (`"security_review_results"`) and displayed in the standing inventory report alongside the judge's test results.

## Technical Context

- **Language/Version**: Elixir ~> 1.20
- **Primary Dependencies**: `:jason` (already in `mix.exs`)
- **Storage**: term-file via GenServer (`data/security_review_results.term`)
- **Testing**: ExUnit (run via `mix test`)
- **Target Platform**: BEAM/OTP Control Plane
- **Project Type**: library module & state store
- **Performance Goals**: <50ms overhead (excluding LLM round-trip)
- **Constraints**: No live network requests during tests (uses `:provider_fn` test seam). Prompt-hardened XML wraps and instruction neutralization prompts.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Direct Implications for This Feature |
|---|---|---|
| I. Simplicity First | PASS | Implement as a functional pipeline using standard OTP constructs. No external dependencies added. |
| II. Explicit Scope | PASS | Only implements code checks and inventory updates; does not mutate deployment state or the physical gate. |
| III. Test-Driven | PASS | ExUnit backend tests written and verified before finalizing code. |
| IV. No Live Deps in Tests | PASS | Uses `:provider_fn` seam in InferenceBroker to execute tests offline. |
| V. Strong Typing | PASS | Verdict struct defined with typespecs and `@enforce_keys`. |
| VIII. Legibility | PASS | Persists reviews to disk and renders them in the standing inventory. |
| IX. Substrate Owns State | PASS | Stored in supervised single-writer `"security_review_results"` GenServer. Agent-specific terminology kept inside manifests. |
| XI. Gate is Only Firewall | PASS | Security review is explicitly a "smoke detector" (pre-deploy alert), not the gate. It does not carry credentials or bypass the runtime gate. |

## Project Structure

### Documentation (this feature)

```text
specs/016-security-review/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Evasion mitigation prompts and decisions
├── data-model.md        # Verdict struct definition
├── quickstart.md        # Code examples and mock-testing templates
├── checklists/
│   └── requirements.md  # Quality validation checklist (passed)
└── contracts/
    └── security-review-api.md # API contracts and validation guards
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── application.ex    # Register "security_review_results" StateStore
    ├── inventory.ex      # Retrieve and render security review verdicts
    └── pipeline/
        └── stage5_review.ex # [NEW] Stage 5 review and prompts logic

test/
└── agent_os/
    └── pipeline/
        └── stage5_review_test.exs # [NEW] Stage 5 test suite
```

**Structure Decision**: The single-project Elixir layout is used. The new module resides under `lib/agent_os/pipeline/` and the tests reside in `test/agent_os/pipeline/`.

## Complexity Tracking

*No violations of the constitution were introduced; no complexity justification needed.*
