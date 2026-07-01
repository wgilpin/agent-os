# Implementation Plan: Consent Screen UI

**Branch**: `023-consent-screen-ui` | **Date**: 2026-07-01 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/023-consent-screen-ui/spec.md)
**Input**: Feature specification from `/specs/023-consent-screen-ui/spec.md`

## Summary
The goal is to implement the Consent Screen UI — a Phoenix/LiveView screen (`AgentOSWeb.ConsentLive`) mounted at `/consent` that renders the deterministic capability presentation for a given manifest. It provides explicit **Approve** and **Reject** buttons, recording human consent and unblocking/blocking downstream execution.

## Technical Context

**Language/Version**: Elixir 1.15+ (OTP 26)  
**Primary Dependencies**: `phoenix`, `phoenix_live_view`, `phoenix_html`, `plug_cowboy`  
**Storage**: Transient StateStores (`pending_approvals`, `provenance`)  
**Testing**: ExUnit via `mix test`  
**Target Platform**: BEAM / Host Substrate (accessible via port 4000)  
**Project Type**: Web service layered on Elixir substrate  
**Performance Goals**: Rendering under 50ms, instant response upon state transition  
**Constraints**: Plain static CSS only, minimal JavaScript, reuse existing root layout.  
**Scale/Scope**: Single concurrent session per browser client.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Simplicity First (Pass)**: No complex build pipeline (Tailwind/esbuild configurations). Direct vanilla CSS styling.
- **III. Test-Driven Backend (Pass)**: Integration tests (`consent_live_test.exs`) drive development of features, states, and transitions.
- **IV. No Live Dependencies in Tests (Pass)**: Tests run against in-memory state stores and local files.
- **V. Strong Typing (Pass)**: Strict socket assigns typing and typespecs on LiveView callbacks.
- **VI. Loud Failures (Pass)**: Lookups or parsing errors from `entries/1` raise and are surfaced to the UI.
- **IX. The Substrate Owns State & Lifecycle (Pass)**: The LiveView is a pure presentation layer over StateStore concepts.
- **X. No Ambient Authority (Pass)**: Capabilities are fetched from registry via entries/1. The LiveView never invents or hardcodes grant descriptions.

## Project Structure

### Documentation (this feature)

```text
specs/023-consent-screen-ui/
├── plan.md              # This file
├── research.md          # Research on parameters & failure modes
├── data-model.md        # UI assigns and validation rules
├── quickstart.md        # Commands to verify and run
└── contracts/
    └── consent-ui.md    # Action contracts and path mappings
```

### Source Code (repository root)

```text
lib/agent_os_web/
├── live/
│   └── consent_live.ex  # [NEW] The Consent Screen LiveView controller
├── router.ex            # [MODIFY] Mount /consent route
priv/static/
└── app.css              # [MODIFY] Append style classes for badges and cards
test/agent_os_web/
└── consent_live_test.exs # [NEW] LiveView integration tests
```

**Structure Decision**: Phoenix files are organized under `lib/agent_os_web/` and static assets under `priv/static/`, maintaining standard Phoenix project structure.

---

## Proposed Changes

### Web Interface

#### [NEW] [consent_live.ex](file:///Users/will/projects/agent_os/lib/agent_os_web/live/consent_live.ex)
- Defines `AgentOSWeb.ConsentLive` using `Phoenix.LiveView`.
- In `mount/3`:
  - Retrieves `manifest` path from query params.
  - Loads manifest via `AgentOS.Manifest.load/1`.
  - Resolves matching pending approval ref from the `pending_approvals` StateStore.
  - Retrieves capabilities via `AgentOS.CapabilityRender.entries/1`.
  - Rescues any runtime exceptions, assigning `:error` status and surfacing the error message.
- Renders:
  - Manifest purpose.
  - Spend cap and window.
  - Grouped capability list sorted by danger (external first, local, then read-only).
  - High-visibility danger badges (`EXTERNAL` emphasised).
  - Explicit **Approve** and **Reject** buttons (only visible if state is `:pending`).
  - Appropriate confirmation alerts for success/failure/rejection.
- In `handle_event/3`:
  - `"approve"`: Records provenance as `:reviewed_human` with manifest hash. Submits `{:approval, :approve, ref}` to `TriggerGateway`. Transitions status to `:approved`.
  - `"reject"`: Submits `{:approval, :deny, ref}` to `TriggerGateway`. Transitions status to `:rejected`.

#### [MODIFY] [router.ex](file:///Users/will/projects/agent_os/lib/agent_os_web/router.ex)
- Add the route:
  ```elixir
  live "/consent", ConsentLive, :index
  ```

#### [MODIFY] [app.css](file:///Users/will/projects/agent_os/priv/static/app.css)
- Add CSS classes for the consent card, danger badges (`danger-badge-external`, `danger-badge-local`, `danger-badge-read_only`), capability group styling, and list layout.

---

### Verification & Testing

#### [NEW] [consent_live_test.exs](file:///Users/will/projects/agent_os/test/agent_os_web/consent_live_test.exs)
- Test suite ensuring:
  - Correct rendering of phrases, badges, scopes, and spend cap.
  - Clicking **Approve** triggers `TriggerGateway` and records provenance.
  - Clicking **Reject** transitions UI and aborts execution.
  - Missing connectors trigger Registry error rendering on screen.

---

## Verification Plan

### Automated Tests
```bash
mix test test/agent_os_web/consent_live_test.exs
```

### Manual Verification
1. Start `mix phx.server` locally.
2. Visit `http://localhost:4000/consent?manifest=manifests/discovery.md`.
3. Check UI layout, sorting, badges, scoping elements.
4. Verify Approve / Reject click flows.
