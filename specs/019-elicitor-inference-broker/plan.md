# Implementation Plan: Route Elicitor through Inference Broker

**Branch**: `019-elicitor-inference-broker` | **Date**: 2026-07-01 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/019-elicitor-inference-broker/spec.md)
**Input**: Feature specification from `/specs/019-elicitor-inference-broker/spec.md`

## Summary

The Spec Elicitor (Python workload) currently makes direct OpenRouter completion calls via `urllib` using a local `MODEL_KEY`. This bypasses the substrate-side `InferenceBroker` chokepoint, rendering the "sole holder of the inference credential key" invariant false, bypassing µ$ metering/capping, and maintaining two separate client paths.

This plan routes the Elicitor through the substrate UDS proxy (`$INFERENCE_SOCKET` / `POST /v1/inference`), registering a dynamic `run_token` mapped to a system-wide `"elicitor"` agent manifest and metering spend against it in `spend_ledger`.

## Technical Context

**Language/Version**: Elixir ~> 1.20 (substrate), Python 3.11 (workloads)  
**Primary Dependencies**: `Req` (Elixir), `Pydantic` (Python)  
**Storage**: state-store term-files (`spend_ledger`)  
**Testing**: `pytest` (Python), `ExUnit` (Elixir)  
**Target Platform**: Mac/Linux Server  
**Project Type**: Multi-language OTP substrate and Python port workloads  
**Performance Goals**: N/A (interactive onboarding)  
**Constraints**: Pure UDS proxy transport, no `MODEL_KEY` in Python, deterministic mock mode preservation, no live API dependencies in tests.  
**Scale/Scope**: System-level pre-manifest agent pipeline  

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I: Simplicity First**: Pass. We reuse the existing UDS chokepoint and registration pattern instead of introducing new mechanisms.
- **Principle II: Explicit Scope Control**: Pass. No unrelated changes.
- **Principle IV: No Live Dependencies in Tests**: Pass. The existing test suite will continue using mock transport, and the new elicitor integration tests will mock the provider function to assert offline.
- **Principle V: Strong Typing, No Bare Maps**: Pass. Typespecs and structs are used in Elixir, Pydantic models in Python.
- **Principle IX: The Substrate Owns State & Lifecycle**: Pass. The substrate manages the lifecycle of the elicitation token, the spend ledger, and the socket.
- **Principle XI: The Deterministic Gate Is the Only Firewall**: Pass. Credential keys remain substrate-side.

## Project Structure

### Documentation (this feature)

```text
specs/019-elicitor-inference-broker/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
└── quickstart.md        # Phase 1 output
```

### Source Code (repository root)

```text
agents/elicitor/
├── main.py              # Update: Swap urllib OpenRouter calls for UDS socket calls
├── models.py            # Untouched: keep Pydantic schemas
└── test_main.py         # Update: Python elicitor test suite

lib/agent_os/
├── elicitation_session.ex  # Update: Register run_token, configure environment vars
└── inference_broker.ex     # Update: Support global provider_fn application override for testing
```

**Structure Decision**: Single project layout matching the existing Elixir substrate and Python agents under `agents/`.

## Complexity Tracking

> *No constitution check violations.*
