# Implementation Plan: discord-notify

**Branch**: `034-discord-notify` | **Date**: 2026-07-06 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/034-discord-notify/spec.md)
**Input**: Feature specification from `/specs/034-discord-notify/spec.md`

## Summary

Add the `discord_notify` connector, the first egress connector to perform a real outbound network call. It will implement the `AgentOS.Connector` behaviour and perform an HTTPS POST via `Req` to a statically provisioned Discord incoming webhook. The connector operates on a strict `notify` action containing message text, relying on injected credentials without allowing ambient authority to the agent. It utilizes an injectable transport for deterministic tests without a live network.

## Technical Context

**Language/Version**: Elixir (OTP)  
**Primary Dependencies**: `Req` (~> 0.5)  
**Storage**: N/A  
**Testing**: ExUnit with an injectable transport (`Application.get_env/3`)  
**Target Platform**: BEAM  
**Project Type**: Agent OS Connector  
**Performance Goals**: Fast outbound POST; no long-polling.  
**Constraints**: Must fail loudly (Invariant VI). MUST NOT use live dependencies in tests (Invariant IV).  
**Scale/Scope**: 1 connector module, 1 set of unit tests.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- [x] **I. Simplicity First**: Uses standard `Req` and `Application.get_env/3`, no complex job queues or fan-outs.
- [x] **II. Explicit Scope Control**: Limits strictly to a single `notify` method passing plain text.
- [x] **IV. No Live Dependencies in Tests**: Injects a test transport function to intercept network calls in ExUnit.
- [x] **VI. Loud Failures**: Bounces non-2xx status codes and network timeouts as explicit `{:error, reason}` tuples.
- [x] **VIII. Legibility**: Notification sent is logged or recorded via existing output_check.
- [x] **X. No Ambient Authority**: Connector receives the webhook URL at runtime via `CredentialProxy.with_credential/2` and only declares a static credential requirement.

## Project Structure

### Documentation (this feature)

```text
specs/034-discord-notify/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── contracts/
    └── connector.md
```

### Source Code (repository root)

```text
lib/agent_os/connector/
└── discord_notify.ex

test/agent_os/connector/
└── discord_notify_test.exs
```

**Structure Decision**: The connector drops directly into the existing `lib/agent_os/connector/` directory and naturally leverages the existing autodiscovery registry. No separate applications or packages are required.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

*(No violations)*
