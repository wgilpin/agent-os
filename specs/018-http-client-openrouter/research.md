# Research: HTTP Client & OpenRouter Transport

## Decision 1: HTTP Client Dependency

### Decision
Use `Req` (`~> 0.5`) as the HTTP client library for the Agent OS control plane.

### Rationale
- **Modern & Ergonomic**: `Req` has a very simple high-level API (`Req.post/2`) that handles JSON encoding, decoding, and header generation cleanly.
- **Minimal Boilerplate**: Unlike `Finch`, `HTTPoison`, or `Tesla`, `Req` does not require setting up custom supervision trees, client adapters, or process pools for basic use cases. It uses `Finch` internally.
- **Error Handling**: `Req` returns standard response structs (`%Req.Response{}`) or error exceptions (`%Req.TransportError{}`) which map naturally to our error-handling tuples.

### Alternatives Considered
- **Finch**: Raw Finch is highly performant but requires supervisor boilerplate and manual connection pool setup. Since this is a prototype, Finch introduces unnecessary friction.
- **Tesla**: Highly customizable but requires adapter dependencies (like Hackney or Finch) and configuration boilerplate.
- **HTTPoison**: Relies on Hackney, which is a legacy Erlang library and introduces heavier dependency footprint than Finch/Req.

---

## Decision 2: OpenRouter API Schema & Contract

### Decision
Standardize on the OpenAI-compatible chat completions structure for requests and responses.

### Rationale
- **Multi-Model Routing**: OpenRouter routes to multiple models using the exact same request format, using the `model` property to specify the destination.
- **Compatibility**: All major modern models (Gemini, Claude, GPT, Llama) are normalized to the OpenAI chat format by OpenRouter.

---

## Decision 3: Error Mapping Strategy

### Decision
Map HTTP and network-level anomalies to distinct, caller-safe error shapes:
- **HTTP status != 200**: Map to `{:error, {:http_status, status_code}}`
- **Timeout**: Map to `{:error, :timeout}`
- **Other Network Failures**: Map to `{:error, :network_error}`
- **Malformed Response / Missing Usage**: Map to `{:error, :missing_usage}`

### Rationale
- **Stability**: Prevents API exceptions or bad JSON from crashing the GenServer or caller.
- **Granular Metering**: Clearly separates API/auth failures (e.g. 401/429) from client misuse (unpriced model).
