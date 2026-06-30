# Implementation Plan: Stage 1 Elicit Spec

**Branch**: `012-elicit-spec` | **Date**: 2026-06-30 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/012-elicit-spec/spec.md)
**Input**: Feature specification from `/specs/012-elicit-spec/spec.md`

## Summary

Implements the first stage of the v3 agent synthesis pipeline: Elicit Spec. Drives an interactive conversation via a Mix task CLI where the user provides a natural language purpose. Coordinates a Python port process (Elicitor Agent) running a Gemini-3 model to refine intent, perform KISS/minimisation checks, structure capabilities, and write the verified specification to `elicited_spec.json`.

## Technical Context

**Language/Version**: Elixir (Erlang OTP 26+), Python (>=3.11)  
**Primary Dependencies**: Gemini Python SDK (google-genai or google-generativeai), Pydantic (>=2.13)  
**Storage**: JSON file-based state store (`data/elicitation/`) and the final spec written to the target feature folder as `elicited_spec.json`.  
**Testing**: ExUnit (`mix test`) and pytest (`pytest`) with stubs/mocks for Gemini API.  
**Target Platform**: BEAM/OTP + Python container environment.  
**Project Type**: control plane stage / CLI tool.  
**Performance Goals**: interactive speeds (<1s parsing latency outside LLM call).  
**Constraints**: must run above the deterministic gate, must enforce capability minimisation (KISS), must not call live Gemini APIs in tests.  
**Scale/Scope**: interactive elicitor.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Simplicity First)**: PASS. Reuses existing Elixir port patterns and simple CLI standard IO.
- **Principle II (Explicit Scope Control)**: PASS. Elicits specification only. Out-of-scope tasks (manifest emission, code generation) are omitted.
- **Principle III (Test-Driven Backend)**: PASS. Backend CLI and port protocol are tested.
- **Principle IV (No Live Dependencies in Tests)**: PASS. Python tests stub the Gemini API calls.
- **Principle V (Strong Typing, No Bare Maps)**: PASS. Uses Pydantic models for Python Elicitor outputs and Elixir structs with typespecs for the control plane.
- **Principle VI (Loud Failures)**: PASS. Any port exit status, parsing failure, or missing env vars will log to `stderr` and raise/crash.
- **Principle VII (Self-Documenting Through Comments)**: PASS. All new modules, tasks, and scripts will contain docstrings and inline comments explaining intent.
- **Principle VIII (Legibility Is Non-Negotiable)**: PASS. Persists the conversation transcript and draft state on disk, and renders the final spec as JSON.
- **Principle IX (The Substrate Owns State & Lifecycle)**: PASS. State is managed by a GenServer in the Elixir control plane. The Python elicitor agent is invocation-scoped (executes once, returns output, and exits).
- **Principle X (No Ambient Authority)**: PASS. This stage only declares requested capabilities. None of them are self-conferred; the deterministic gate continues to enforce the runtime manifest.
- **Principle XI (The Deterministic Gate Is the Only Firewall)**: PASS. No credentials are used or exposed in the elicitor agent; the gate is uninvolved.
- **Principle XII (Enforcement Precedes Generation)**: PASS. The specification process is built as a separate component prior to the manifest and code generation stages.

## Project Structure

### Documentation (this feature)

```text
specs/012-elicit-spec/
├── plan.md              # This file
├── research.md          # Research findings and schema decisions
├── data-model.md        # Elixir struct and Pydantic models
├── quickstart.md        # Guide to run and test
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── contracts/
    └── elicitor.md      # Port communication protocol contract
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── elicitation.ex          # Struct definitions for spec/session
    ├── elicitation_session.ex  # GenServer managing the active conversation and port runner
    └── mix/
        └── tasks/
            └── agent_os.elicit.ex  # Interactive CLI task driving the loop

agents/
└── elicitor/
    ├── __init__.py
    ├── main.py                 # Elicitor Agent script executing Pydantic Gemini prompt
    ├── models.py               # Pydantic schema schemas
    └── test_main.py            # pytest suite for elicitor script
```

**Structure Decision**: Integrated into existing `lib/agent_os` for Elixir components and `agents/` for Python agent workloads, preserving consistency.

## Complexity Tracking

*No violations. Reuses existing Elixir port patterns and simple CLI standard IO.*

## Verification Plan

### Automated Tests
- Python unit tests:
  ```bash
  uv run pytest agents/elicitor/test_main.py
  ```
- Elixir unit tests:
  ```bash
  mix test test/agent_os/elicitation_test.exs
  ```

### Manual Verification
1. Run the interactive CLI:
   ```bash
   mix agent_os.elicit "watch website X for updates and post to slack"
   ```
2. Respond to the questions, request a creep capability (e.g. "delete messages") and verify the orchestrator warns/pushes back.
3. Confirm the spec and verify `elicited_spec.json` is generated correctly in the feature directory.
