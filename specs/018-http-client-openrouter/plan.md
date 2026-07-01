# Implementation Plan: HTTP Client & OpenRouter Transport

**Branch**: `018-http-client-openrouter` | **Date**: 2026-07-01 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/018-http-client-openrouter/spec.md)
**Input**: Feature specification from `/specs/018-http-client-openrouter/spec.md`

## Summary

Integrate real model completions by implementing outbound HTTP requests to OpenRouter's completions endpoint. We will introduce `Req` as the HTTP client library to post formatted message payloads to `https://openrouter.ai/api/v1/chat/completions`. The key secret is injected dynamically via `CredentialProxy.with_credential/2` and used as a bearer authorization token. Network timeouts, non-200 responses, and validation failures will be mapped to structured error results to avoid crashes.

## User Review Required

- **HTTP Client Library Choice**: Standardizing on `Req` (`~> 0.5`) because it is the modern Elixir standard, highly ergonomic, and does not require custom supervision or pool setup boilerplate for simple HTTP calls.
- **Extended Error Types**: Extended the broker's `:result` type to include structured network errors (`:timeout`, `:network_error`, `{:http_status, integer()}`).

## Open Questions

None.

## Proposed Changes

### Elixir Substrate

---

#### [MODIFY] [mix.exs](file:///Users/will/projects/agent_os/mix.exs)
- Add `{:req, "~> 0.5"}` to the dependency list in `deps/0`.

#### [MODIFY] [inference_broker.ex](file:///Users/will/projects/agent_os/lib/agent_os/inference_broker.ex)
- Extend the `@type result` typespec to support the new error variants: `| {:error, ... | :timeout | :network_error | {:http_status, integer()}}`.
- Replace the placeholder body of `real_provider_fn/3` with a real `Req.post/2` call to OpenRouter.
- Handle success payload parsing (extract choices content and usage data) and mapping:
  - 200 HTTP status with valid JSON: return `%{input_tokens: ..., output_tokens: ..., completion: ...}` map.
  - 200 HTTP status but malformed/missing usage: return `{:error, :missing_usage}`.
  - Non-200 HTTP status (e.g. 401, 429, 500): log status and return `{:error, {:http_status, status}}`.
  - Network-level timeout: return `{:error, :timeout}`.
  - General connection/network failure: return `{:error, :network_error}`.
- Update `InferenceBroker.complete/2` to match and propagate `{:error, reason}` returned by `provider_fn` instead of defaulting to `{:error, :missing_usage}` for all non-map results.

---

### Tests

---

#### [MODIFY] [inference_broker_test.exs](file:///Users/will/projects/agent_os/test/agent_os/inference_broker_test.exs)
- Add test coverage for the extended error shapes by injecting provider functions that return `{:error, :timeout}`, `{:error, {:http_status, 401}}`, etc.

## Verification Plan

### Automated Tests
- Run the full project test suite using `mix test`.
- Run the inference broker tests specifically:
  ```bash
  mix test test/agent_os/inference_broker_test.exs
  ```

### Manual Verification
- Start `iex -S mix` and make manual mock inference broker calls to ensure token registration, spend ledger tracking, and fake provider response parsing are fully operational.
