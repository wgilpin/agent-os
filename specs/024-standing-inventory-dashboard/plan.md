# Implementation Plan: Standing Inventory Dashboard

**Branch**: `024-standing-inventory-dashboard` | **Date**: 2026-07-01 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/024-standing-inventory-dashboard/spec.md)
**Input**: Feature specification from `/specs/024-standing-inventory-dashboard/spec.md`

## Summary
The goal is to implement the Standing Inventory Dashboard — a Phoenix/LiveView page that renders the active agent roster, spend status, and audit logs for every provisioned agent. It reads purely from the substrate's already-computed state without communicating with agent processes.
We will refactor `AgentOS.Inventory` to extract a structured accessor `data/1` and format the CLI output using this data. Then we will build `AgentOSWeb.InventoryLive` and mount it at `/inventory` in `lib/agent_os_web/router.ex`. It will visually display agent rosters, spend, capabilities, audit logs, and poll for changes every 5 seconds.

## Technical Context

**Language/Version**: Elixir 1.15+ (OTP 26)  
**Primary Dependencies**: `phoenix`, `phoenix_live_view`, `phoenix_html`, `plug_cowboy`  
**Storage**: Transient StateStores (`roster_trust`, `spend_ledger`, `pending_approvals`, `conformance`, `provenance`, `judge_results`, `security_review_results`), and the file-backed `data/run_log.md` (via `AgentOS.RunLog.read_records/2`).  
**Testing**: ExUnit via `mix test`  
**Target Platform**: BEAM / Host Substrate (accessible via port 4000)  
**Project Type**: Web service layered on Elixir substrate  
**Performance Goals**: Page loading/refresh under 50ms, polling interval 5000ms.  
**Constraints**: Plain static CSS only, minimal JavaScript, reuse existing root layout.  
**Scale/Scope**: Dynamic listing of all manifests found under `manifests/*.md`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Simplicity First (Pass)**: No complex build pipelines or front-end frameworks. Direct vanilla CSS styling via `priv/static/app.css`.
- **II. Explicit Scope Control (Pass)**: No extra control buttons or capabilities are built. It remains strictly read-only.
- **III. Test-Driven Backend (Pass)**: Backend Refactoring is validated by existing tests and new unit tests. LiveView page verified using Phoenix.LiveViewTest.
- **IV. No Live Dependencies in Tests (Pass)**: Tests run against in-memory state stores and local files.
- **V. Strong Typing (Pass)**: Strict socket assigns and typespecs on the refactored module and the new LiveView.
- **VI. Loud Failures (Pass)**: Errors loading manifests, connectors, or files log warnings/exceptions.
- **VIII. Legibility Is Non-Negotiable (Pass)**: Direct implementation of Legibility by presenting a clear standing inventory dashboard.
- **IX. The Substrate Owns State & Lifecycle (Pass)**: The LiveView is a pure presentation layer over StateStore and file concepts, reading computed substrate state.

## Project Structure

### Documentation (this feature)

```text
specs/024-standing-inventory-dashboard/
├── plan.md              # This file
├── research.md          # Research on accessor design and dynamic listing
├── data-model.md        # Accessor and socket assigns specifications
├── quickstart.md        # Commands to run tests and verify
├── contracts/
│   └── dashboard-ui.md  # Route mapping and HTML markup structure contract
└── tasks.md             # TODO list (to be generated)
```

### Source Code (repository root)

```text
lib/agent_os/
└── inventory.ex         # [MODIFY] Extract data/1, refactor render/1

lib/agent_os_web/
├── live/
│   └── inventory_live.ex # [NEW] Dashboard LiveView
└── router.ex            # [MODIFY] Mount /inventory route

priv/static/
└── app.css              # [MODIFY] Visual styling for cards, grids, badges

test/agent_os/
└── inventory_test.exs   # [MODIFY] Assert data/1 returns same values as render/1

test/agent_os_web/
└── inventory_live_test.exs # [NEW] Test dynamic rendering and polling of dashboard
```

**Structure Decision**: Phoenix files are organized under `lib/agent_os_web/` and static assets under `priv/static/`, maintaining standard Phoenix project structure.

## Complexity Tracking

*(No violations)*
