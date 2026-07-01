# Research: Secure Secret Provisioning

## Technical Decisions & Choices

### 1. Unified Credential Source (`AgentOS.CredentialSource`)
We will create a module `AgentOS.CredentialSource` containing `resolve_credentials/0`. This module will:
- Check for the existence of `.env` in the project root, stream the file, parse definitions, and load them into the OS environment using `System.put_env/2`.
- Retrieve `MODEL_KEY` and `OUTBOUND_TOKEN` from the OS environment via `System.get_env/1`.
- If missing or blank (meaning `nil`, `""`, or containing only whitespace), it falls back to the application environment configuration (e.g. for testing) and performs strict presence validation.
- Filter out any missing/blank values from the resolved map so they are completely absent from `CredentialProxy`'s state.

#### Rationale
Encapsulating this logic behind a single named function isolates the environment parsing and environment variable reading. It removes compile-time capture from `config.exs` and replaces the custom inline logic in `application.ex` cleanly, allowing dedicated unit testing.

---

### 2. Startup Diagnostics & Fail-Closed Behavior
At startup, `AgentOS.Application.start/2` will call `AgentOS.CredentialSource.resolve_credentials/0`. If `:model_key` is missing or blank:
- The system will log a critical startup diagnostic: `Logger.error("CRITICAL: Required model credential :model_key is missing or blank.")`.
- It will NOT crash the supervisor tree, which ensures the rest of the application boots and tests pass normally.
- At inference call time, because `CredentialProxy` does not hold the `:model_key` key, it will return `{:error, {:unknown_credential, :model_key}}`.
- As a defensive fallback, the `real_provider_fn/3` function in `InferenceBroker` will explicitly validate that the secret passed is non-empty and non-blank before making any HTTP Req calls, returning `{:error, :missing_credential}` if invalid.

#### Rationale
This provides two independent layers of security: blocking the execution inside `CredentialProxy` (so the secret closure is never run), and guarding inside the provider function itself (preventing Bearer headers from being built with empty/whitespace values under any circumstances).

---

### 3. Port Boundary Environment Scrubbing
We will update `AgentOS.PortRunner.run/4` to configure the Erlang port's environment with `env: [{"MODEL_KEY", false}, {"OUTBOUND_TOKEN", false}]`.

#### Rationale
Erlang ports inherit the host's environment by default. By explicitly passing `false` for these keys, Erlang clears them from the spawned wrapper script's environment. This guarantees that host API keys never cross the port boundary into sandboxed agent containers.

---

## Alternatives Considered

- **Crashing Application on Boot on Missing Secret**: Rejected because it breaks test scenarios and other agent workloads that do not use model APIs but still require the application to boot. A clear log diagnostic combined with runtime fail-closed API errors is safer.
- **Using third-party `.env` packages**: Rejected in favor of the existing simple stream-based parser to avoid pulling in external dependencies, in line with Principle I (Simplicity First).
