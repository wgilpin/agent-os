# Implementation Plan: Secure Secret Provisioning

**Branch**: `020-secure-secret-provisioning` | **Date**: 2026-07-01 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/020-secure-secret-provisioning/spec.md)
**Input**: Feature specification from `/specs/020-secure-secret-provisioning/spec.md`

## Summary
Move API key configuration from compile-time `config.exs` to runtime environment loading via a new module `AgentOS.CredentialSource`. Scrub host model API keys at the port boundary inside `AgentOS.PortRunner` to prevent untrusted python agents from accessing host secrets. Log startup diagnostics when required keys are missing, and fail-closed cleanly at inference time.

## Technical Context

**Language/Version**: Elixir (Erlang/OTP 26+)  
**Primary Dependencies**: None (Req for HTTP transport, already installed)  
**Storage**: In-memory (no persistence)  
**Testing**: ExUnit (`mix test`)  
**Target Platform**: BEAM VM / Docker container sandbox  
**Project Type**: OTP control plane (library/service)  
**Performance Goals**: <1ms overhead for local credential lookups, <100ms for blocked inference checks.  
**Constraints**: No vault or external secret manager integration, no secrets in compile-time artifacts, strict sandbox separation.  
**Scale/Scope**: Env-only credentials provider.  

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I: Simplicity First**: Passed. Pure environment variables and a simple stream-based `.env` parser are used, without introducing pluggable adapters or complex abstractions.
- **Principle II: Explicit Scope Control**: Passed. Only solving the credential loading, validation, and boundary scrubbing as requested.
- **Principle IV: No Live Dependencies in Tests**: Passed. The test suite uses local mock functions and does not contact live APIs.
- **Principle X: No Ambient Authority / Principle XI: Deterministic Gate**: Passed. Scrubbing environment variables at the port boundary ensures untrusted agents have no access to host credentials.

## Project Structure

### Documentation (this feature)

```text
specs/020-secure-secret-provisioning/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── checklists/
    └── requirements.md  # Spec checklist
```

### Source Code (repository root)

```text
config/
└── config.exs           # [MODIFY] Remove compile-time env reads for credentials

lib/agent_os/
├── application.ex       # [MODIFY] Check for model key, log startup diagnostic, remove inline .env loader
├── credential_proxy.ex  # [MODIFY] Initialize from CredentialSource instead of config
├── credential_source.ex # [NEW] Consolidated resolver for env and .env file loading
├── inference_broker.ex  # [MODIFY] Guard real_provider_fn/3 against empty secrets
└── port_runner.ex       # [MODIFY] Scrub environment variables at the Port boundary

test/agent_os/
├── credential_proxy_test.exs  # [MODIFY] Validate compatibility with updated initialization
└── credential_source_test.exs # [NEW] Test env loading, .env parsing, and missing/blank keys
```

**Structure Decision**: Standard single project. Modifying existing core control-plane components under `lib/agent_os/` and adding `credential_source.ex` as the single point of entry for secret loading.

## Proposed Changes

---

### Component: Substrate Configuration & Initialization

#### [MODIFY] [config.exs](file:///Users/will/projects/agent_os/config/config.exs)
- Remove `System.get_env("MODEL_KEY")` and `System.get_env("OUTBOUND_TOKEN")` from the main `config :agent_os` block (lines 23-26) to prevent compile-time capture.
- Set the default main config `:credentials` map to `%{}`.
- Retain the test credentials in `if config_env() == :test do` block so the tests continue to have access to mock test values.

#### [NEW] [credential_source.ex](file:///Users/will/projects/agent_os/lib/agent_os/credential_source.ex)
- Implement `AgentOS.CredentialSource.resolve_credentials/0`.
- Include standard stream-based parsing of `.env` files (if present) to populate the OS environment via `System.put_env/2`.
- Read and validate `MODEL_KEY` and `OUTBOUND_TOKEN`.
- Discard/exclude keys with `nil`, `""`, or whitespace-only values.
- Fall back to the application configuration environment map as a secondary source (primarily for test environments).

#### [MODIFY] [application.ex](file:///Users/will/projects/agent_os/lib/agent_os/application.ex)
- Replace `load_env_file/0` and the inline `.env` parser completely with a call to `AgentOS.CredentialSource.resolve_credentials/0`.
- Perform a startup check: if the resolved `:model_key` is missing/blank, log a clear diagnostic warning/error via `Logger.error/1`.

#### [MODIFY] [credential_proxy.ex](file:///Users/will/projects/agent_os/lib/agent_os/credential_proxy.ex)
- Update `init/1` to load credentials by calling `AgentOS.CredentialSource.resolve_credentials/0` rather than reading directly from the compile-time application environment.

#### [MODIFY] [inference_broker.ex](file:///Users/will/projects/agent_os/lib/agent_os/inference_broker.ex)
- Add a runtime check inside `real_provider_fn/3`: return `{:error, :missing_credential}` if the passed secret is `nil`, `""`, or contains only whitespace, ensuring we never build a Bearer token with blank values.

#### [MODIFY] [port_runner.ex](file:///Users/will/projects/agent_os/lib/agent_os/port_runner.ex)
- Update `Port.open/2` options to include `env: [{"MODEL_KEY", false}, {"OUTBOUND_TOKEN", false}]`. This forces Erlang to scrub these variables from the environment of any spawned port command or container.

---

### Component: Testing

#### [NEW] [credential_source_test.exs](file:///Users/will/projects/agent_os/test/agent_os/credential_source_test.exs)
- Test that `.env` parsing successfully populates the OS environment.
- Test that missing keys are filtered out and excluded.
- Test that whitespace-only credentials are treated as blank and excluded.
- Test that valid environment variables are correctly loaded and returned.

---

## Verification Plan

### Automated Tests
- Run `mix test` to verify no regressions in the state stores, gates, and inference broker.
- Run `mix test test/agent_os/credential_source_test.exs` to verify the resolver works under all test cases.

### Manual Verification
- Start the application with a blank or whitespace `MODEL_KEY` and verify the startup error log is emitted.
- Execute an inference request with no key to ensure it returns a clean `{:error, {:unknown_credential, :model_key}}` and does not make an outbound Req call.
