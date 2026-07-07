# Implementation Plan: Discord Gateway Ingress

**Branch**: `036-discord-ingress` | **Date**: 2026-07-06 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/036-discord-ingress/spec.md)
**Input**: Feature specification from `/specs/036-discord-ingress/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command. See `.specify/templates/plan-template.md` for the execution workflow.

## Summary

Stand up a substrate-supervised Discord ingress that receives the user's reply in the configured channel and feeds it into the waiting agent's message trigger. The ingress maintains a long-lived websocket to the Discord Gateway using `websockex`, authenticates, filters messages by authorized user and channel, and routes them to `AgentOS.TriggerGateway.submit/1`.

## Technical Context

**Language/Version**: Elixir (BEAM/OTP)
**Primary Dependencies**: `websockex`
**Storage**: N/A
**Testing**: `ExUnit`
**Target Platform**: BEAM (Linux/macOS)
**Project Type**: Substrate control-plane service
**Performance Goals**: N/A (low volume, single user)
**Constraints**: Supervised, must not crash the entire substrate on socket failure
**Scale/Scope**: 1 authorized user, 1 channel

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- [x] **I. Simplicity First**: Using a standard Elixir websocket library instead of complex alternatives.
- [x] **II. Explicit Scope Control**: Only fetching messages from one user/channel, directly feeding into existing triggers.
- [x] **III. Test-Driven Backend**: Logic will be tested with mocked websocket payloads.
- [x] **IV. No Live Dependencies in Tests**: Mocking the gateway connection for tests.
- [x] **VI. Loud Failures**: All drops (wrong user/channel) and crashes are heavily logged.
- [x] **IX. The Substrate Owns State**: Substrate routes messages, does not persist correlation state.
- [x] **X. No Ambient Authority**: Discord bot token fetched securely via CredentialSource, never observable by agents.

## Project Structure

### Documentation (this feature)

```text
specs/036-discord-ingress/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
lib/agent_os/
├── discord_gateway.ex       # The websockex client and supervisor
└── application.ex           # Updated to supervise AgentOS.DiscordGateway

test/agent_os/
└── discord_gateway_test.exs # Tests for payload matching and triggering
```

**Structure Decision**: Elixir app structure, added directly into `lib/agent_os/`.
