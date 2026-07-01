# Implementation Plan: Interactive Elicitation UI

**Branch**: `022-elicitation-ui` | **Date**: 2026-07-01 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/022-elicitation-ui/spec.md)
**Input**: Feature specification from `/specs/022-elicitation-ui/spec.md`

## Summary
The goal is to implement a Phoenix/LiveView web interface that allows users to interactively converse with the elicitation orchestrator, achieving behavioral parity with the `mix agent_os.elicit` CLI command. We layer the Phoenix Endpoint on top of the existing supervision tree without restructuring the codebase, and manage the `ElicitationSession` lifecycle cleanly.

## Technical Context

**Language/Version**: Elixir 1.15+ (OTP 26)  
**Primary Dependencies**: `phoenix`, `phoenix_live_view`, `phoenix_html`, `plug_cowboy`  
**Storage**: Transient GenServer states, files written to `specs/012-elicit-spec/elicited_spec.json` and `data/elicitation/`.  
**Testing**: ExUnit (run via `mix test`)  
**Target Platform**: BEAM / Host Substrate (accessible via browser on port 4000)  
**Project Type**: Phoenix/LiveView web service layered on top of Elixir OTP Substrate  
**Performance Goals**: Page rendering under 50ms, live spec dynamic updates under 200ms of turn completion.  
**Constraints**: Clean termination of session GenServers upon socket disconnect to avoid memory leaks. No JS compilation build step (direct assets served from `:agent_os` and deps).  
**Scale/Scope**: Single concurrent session per browser client connection.  

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Simplicity First (Pass)**: Avoids complex asset compilation (Tailwind/esbuild configuration). Serves dependencies (`phoenix.js`, `phoenix_live_view.js`) directly via `Plug.Static` routes.
- **III. Test-Driven Backend (Pass)**: ExUnit integration tests will drive the LiveView flow step-by-step.
- **IV. No Live Dependencies in Tests (Pass)**: Mock port runners or elicitation stubs are used during tests to ensure deterministic runs.
- **V. Strong Typing (Pass)**: Typespecs for all new controllers, live views, and custom socket assigns.
- **IX. The Substrate Owns State & Lifecycle (Pass)**: LiveView acts as a thin presenter over `ElicitationSession`, linking its process to prevent leaks.

## Project Structure

### Documentation (this feature)

```text
specs/022-elicitation-ui/
├── plan.md              # This file
├── research.md          # Research on asset serving and process linkage
├── data-model.md        # Data views and validation
└── quickstart.md        # Verification and startup commands
```

### Source Code (repository root)

```text
config/
├── config.exs           # Define endpoint port, salt, json parser, and server status

lib/agent_os/
├── application.ex       # Start Phoenix PubSub and Endpoint in supervisor tree

lib/agent_os_web/
├── layouts/
│   ├── root.html.heex   # Root HTML document wrapper
│   └── app.html.heex    # Main application body wrapper
├── live/
│   └── elicitation_live.ex  # Core LiveView controller
├── endpoint.ex          # Phoenix Endpoint configuration
├── router.ex            # Scope and live view routing
├── layouts.ex           # Layout embedding wrapper
└── error_html.ex        # Standalone error handler

priv/static/
├── app.css              # Custom styles matching Elicitor Design System
└── app.js               # Client socket startup and hook attachment

test/agent_os_web/
└── elicitation_live_test.exs  # Integration tests for landing, turns, warning, and confirm
```

**Structure Decision**: Phoenix files are organized under the `lib/agent_os_web/` namespace inside the single Mix project structure, keeping it isolated from `lib/agent_os/` business logic.

## Complexity Tracking

*No violations to track.*
