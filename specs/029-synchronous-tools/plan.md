# Implementation Plan: Synchronous Tools + Web Search

**Branch**: `029-synchronous-tools` | **Date**: 2026-07-02 | **Spec**: [/specs/029-synchronous-tools/spec.md](file:///Users/will/projects/agent_os/specs/029-synchronous-tools/spec.md)
**Input**: Feature specification from `/specs/029-synchronous-tools/spec.md`

## Summary

This plan adds a synchronous, mid-inference tool-use channel over the `AgentOS.InferenceBroker`. It allows agents to pause reasoning, execute registered tool connectors, inject the results back into context, and proceed in a single agent-side invocation. The web_search connector will be the first tool connector implemented, utilizing the auto-discovered behaviour registry from 08-01.

## Technical Context

**Language/Version**: Elixir 1.15+ / OTP 26+  
**Primary Dependencies**: Standard Library (`Task.Supervisor`, `Registry`), OpenRouter Completions API  
**Storage**: state_store (spend_ledger)  
**Testing**: ExUnit  
**Target Platform**: BEAM virtual machine  
**Project Type**: library/control-plane substrate  
**Performance Goals**: <50ms tool resolution overhead, execution timeboxed to 5 seconds  
**Constraints**: Fully backwards-compatible with existing arity-3 mock `provider_fn` definitions in the 40+ existing tests.  
**Scale/Scope**: 1 new tool connector (`web_search`), modification to `InferenceBroker` core logic.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Simplicity First)**: Passed. Integrates directly into `InferenceBroker.complete/2` with a tail-recursive function loop. No external tool-routing orchestration framework.
- **Principle II (Explicit Scope Control)**: Passed. Focuses solely on Phase 08-02. Does not implement `kv_read` or parallel tool executions.
- **Principle IV (No Live Dependencies in Tests)**: Passed. Upstream web_search and OpenRouter completions will be mocked/stubbed in the test suite.
- **Principle V (Strong Typing)**: Passed. Defines Elixir typespecs for the new `execute_tool/2` callback.
- **Principle IX (Substrate Owns State & Lifecycle)**: Passed. Tool schemas are dynamically constructed from auto-discovered connector metadata; no hardcoding of specific tools in `InferenceBroker` core list.
- **Principle X (No Ambient Authority)**: Passed. Tools are only advertised and runnable if they are granted in the agent's manifest. Enforcement occurs substrate-side before execution.

## Project Structure

### Documentation (this feature)

```text
specs/029-synchronous-tools/
├── plan.md              # This file
├── research.md          # Research findings
├── data-model.md        # Entities & state changes
├── quickstart.md        # Walkthrough of manual verification
└── tasks.md             # Implementation tasks
```

### Source Code (repository root)

```text
lib/
└── agent_os/
    ├── connector.ex               # [MODIFY] Add execute_tool/2 optional callback & specs
    ├── inference_broker.ex        # [MODIFY] Implement tool call loop, tool schemas, and billing
    └── connector/
        └── web_search.ex          # [NEW] WebSearch tool connector implementing behavior

test/
└── agent_os/
    └── inference_broker_test.exs  # [MODIFY] Add unit tests for tool schema ads, execution, metering, and error recovery
```

**Structure Decision**: Single project structure matching current workspace patterns.

## Complexity Tracking

*No violations identified.*
