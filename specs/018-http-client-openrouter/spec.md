# Feature Specification: HTTP Client & OpenRouter Transport

**Feature Branch**: `018-http-client-openrouter`  
**Created**: 2026-07-01  
**Status**: Draft  
**Input**: User description: "Phase 5 plan 05-01: HTTP Client & OpenRouter Transport. Replace the stubbed real_provider_fn/3 in lib/agent_os/inference_broker.ex (currently a hardcoded placeholder returning zero-token completions — comment reads 'Placeholder return, will be replaced with real Gemini call when implemented') with a real outbound HTTP call to OpenRouter's chat completions API. OpenRouter is the sole transport: it is a multi-model router, so any model string (Gemini, Claude, GPT, Llama, etc.) is just a `model` field routed through the same OpenRouter endpoint — there is no separate per-provider client to build. Add an HTTP client dependency to mix.exs — none exists yet (deps are only jason and yaml_elixir; no Req, Finch, HTTPoison, or Tesla) — and use it to POST the model + messages to OpenRouter's /chat/completions endpoint. Use the model_key secret already threaded through CredentialProxy.with_credential(:model_key, fn secret -> provider_fn.(model, messages, secret) end) at inference_broker.ex:113 as the Authorization bearer token (OpenRouter API key) — the credential-injection wiring already exists end to end, only the closure body needs a real implementation. Parse OpenRouter's response into the existing %{input_tokens:, output_tokens:, completion:} usage shape that InferencePrice.micro_dollars/2 already consumes, so the spend-metering and breach-check logic in InferenceBroker.complete/2 needs no changes. Handle HTTP failure modes the stub never had to face — network errors, timeouts, non-200 responses, malformed or missing-usage responses — mapping them to the broker's existing {:error, ...} result shapes (extending the result type as needed) rather than crashing the GenServer or the caller process. Scope boundaries: Do NOT change how the model_key secret is loaded or provisioned. CredentialProxy still reads from Application.get_env(:agent_os, :credentials) / the MODEL_KEY env var as-is. Do NOT build dynamic price-table sync. The static inference_prices map in config/config.exs, keyed by model string, stays exactly as-is. Testing constraint: the existing :provider_fn option on InferenceBroker.complete/2 already supports injecting a fake transport — tests must use it so the suite never makes live network calls to OpenRouter."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Successful Inference via OpenRouter (Priority: P1)

An agent requests text completion for a supported model (e.g., Gemini, Claude, GPT) by passing its model identifier and message history. The system securely calls the central model routing service, retrieves the completion, parses the model usage and completion content, and updates the agent's spend ledger based on configured pricing.

**Why this priority**: This is the core functionality that enables agents to perform real model queries instead of getting hardcoded empty placeholders.

**Independent Test**: Register an agent, set the pricing for a mock model, and call the inference broker with a mock/fake provider function that simulates a successful router HTTP response. Verify the spend ledger is updated with the correct cost and the completion text is returned.

**Acceptance Scenarios**:

1. **Given** a registered agent with a valid API key, **When** an inference request is made for a priced model, **Then** the request is formatted correctly for the routing endpoint, the token usage and completion text are extracted from the response, and the broker updates the agent's ledger and returns the completion.

---

### User Story 2 - Robust HTTP Failure Handling (Priority: P1)

An agent makes an inference request, but the outbound network request fails due to a network disruption, timeout, HTTP error status (such as 401, 429, or 500), or a response containing malformed JSON. The system intercepts the failure and returns a structured error to the caller, preventing the broker GenServer or caller process from crashing.

**Why this priority**: Outbound API calls are inherently unreliable; failures must be handled gracefully to prevent system-wide instability or silent crashes.

**Independent Test**: Call the inference broker with provider functions configured to simulate network timeouts, connection failures, non-200 status codes, and empty/malformed payloads. Verify the broker returns the expected error tuples (e.g., `{:error, :timeout}`, `{:error, {:http_error, status_code}}`, `{:error, :missing_usage}`).

**Acceptance Scenarios**:

1. **Given** a network connection failure or timeout, **When** an inference request is made, **Then** the broker returns a structured error representing the network or timeout failure.
2. **Given** a non-200 HTTP response from the model router, **When** an inference request is made, **Then** the broker returns a structured error containing the status code.
3. **Given** a 200 HTTP response with missing token usage metadata or malformed JSON, **When** an inference request is made, **Then** the broker returns `{:error, :missing_usage}`.

---

### User Story 3 - Test Isolation (Priority: P2)

A developer runs the system's test suite. The test suite verifies the broker's metering, cap enforcement, and response validation logic without initiating any actual outbound HTTP connections to the model router.

**Why this priority**: Testing must be fast, offline-capable, deterministic, and prevent accidental utilization of live API credits or exposure of API credentials.

**Independent Test**: Run the test suite and verify that all tests pass without making real network connections, using the broker's `:provider_fn` dependency injection mechanism.

**Acceptance Scenarios**:

1. **Given** the test environment, **When** the standard test command is run, **Then** no outbound HTTP requests to the model router are initiated, and all assertions pass.

---

### Edge Cases

- **Unauthorized / Invalid API Keys**: If the external routing service returns a `401 Unauthorized` response, the broker maps it to a structured error like `{:error, {:http_status, 401}}` so the system knows the credentials are invalid.
- **Rate Limiting (429)**: When the service responds with a `429 Too Many Requests` status, the broker maps it to a structured error without crashing or looping infinitely.
- **Empty / Incomplete Usage Data**: If the service returns a success status but is missing the `usage` map or returns `null` values for token counts, the broker treats it as a validation failure and returns `{:error, :missing_usage}`.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST perform outbound HTTP POST requests to the central model router's completions endpoint (`/chat/completions`) using an HTTP client.
- **FR-002**: The system MUST format the request body with the exact model identifier and list of messages requested by the caller.
- **FR-003**: The system MUST pass the model API key as a bearer token in the HTTP Authorization header, retrieved dynamically via the existing credentials proxy framework.
- **FR-004**: The system MUST parse the JSON response to extract the completion text, input token usage, and output token usage.
- **FR-005**: The system MUST catch and handle network-level connection failures, mapping them to standard error return values (e.g., `{:error, :network_error}`).
- **FR-006**: The system MUST catch and handle HTTP request timeouts, mapping them to standard error return values (e.g., `{:error, :timeout}`).
- **FR-007**: The system MUST check the HTTP response status code and return a structured error (e.g., `{:error, {:http_status, status}}`) for any non-200 response.
- **FR-008**: The system MUST return `{:error, :missing_usage}` if the response body is malformed or lacks token usage metadata, matching the existing broker error shape.
- **FR-009**: The system MUST NOT make live outbound HTTP requests during automated test suite execution, relying instead on injecting mocked provider functions.

### Key Entities

- **Model Router Request**: The serialized request payload containing the model identifier, message history, and optional routing headers.
- **Model Router Response**: The parsed JSON response containing the generated text completion and token metadata (`usage.prompt_tokens` and `usage.completion_tokens`).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of successful completions return the parsed text and update the ledger with the exact token costs calculated using the price table.
- **SC-002**: 100% of network failures, timeouts, and non-200 responses return caller-safe `{:error, ...}` tuples without crashing the broker process.
- **SC-003**: Zero HTTP requests to the live router are initiated during tests.

## Assumptions

- The central model router's completion endpoint follows the standard OpenAI-compatible completions API structure.
- The credentials proxy dynamically provides a valid OpenRouter API key.
- The local model price table mapped in configuration remains static and does not need dynamic synchronization with the router.
