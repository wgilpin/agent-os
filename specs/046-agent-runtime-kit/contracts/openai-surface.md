# Contract — Broker OpenAI-compatible surface

**Endpoint**: `POST /v1/chat/completions` on the InferenceBroker UDS listener (`lib/agent_os/inference_broker.ex`).
**Coexists with**: `POST /v1/inference` (native envelope — UNCHANGED) and `POST /v1/tool_calls` (direct tool channel — UNCHANGED). Routing is by request path in `route_request/3`.

## Authentication

- Run token presented as `Authorization: Bearer <run_token>` (NOT in the JSON body — the body is framework-owned OpenAI shape).
- `read_http_request/2` must be extended to capture the `Authorization` header and thread it to the route handler. The native path continues to read `run_token` from the body and is untouched.
- Resolution reuses `resolve/1` (the same token → `{agent_name, manifest, effective_model, mode}` map). Unknown/missing/malformed token → **401**, no upstream call, no metering.

## Request

```jsonc
{ "model": "<string>",           // pydantic-ai sends AGENT_MODEL; broker prefers resolved.effective_model
  "messages": [ … ],             // OpenAI chat messages
  "tools": [ … ]                 // optional; framework-declared function tools (passed through to provider)
}
```

- `stream: true` (or any unsupported OpenAI extra) → **400**, cleanly refused. No silent partial support.

## Behaviour (single metered turn — NO server-side tool loop)

1. Resolve Bearer token → agent/manifest (401 on failure).
2. Look up price for the effective model (`InferencePrice.lookup/2`); unpriced → **400** `unpriced_model`.
3. Normalize the spend window (`SpendLedger.current_entry/3`); persist if reset.
4. **Pre-check cap**: `spent >= cap` → **402** `spend_breach` (kill-on-breach identical to native).
5. Call the provider ONCE via `CredentialProxy.with_credential(:model_key, …)` with `(model, messages, tools, secret)` — the credential never leaves the broker; `MODEL_KEY` stays scrubbed from the agent.
6. Meter usage: `dollars = InferencePrice.micro_dollars(usage, price_entry)`; write `{:put, agent_name, %{spent: spent+dollars, window_start: now}}` to `spend_ledger`.
7. **Post-meter cap check**: crossing the cap → **402** `spend_breach`.
8. Serialize the provider `message` + `usage` into an OpenAI `chat.completion` and return **200**.

Crucially: the broker does **not** execute tools or recurse. The framework in the body executes plain in-body tools and issues the next `/v1/chat/completions` request itself. Each request = one discrete metered call ⇒ spend reconciles call-for-call (FR-007, SC-003).

## Responses

| Status | When | Body |
|---|---|---|
| 200 | success | OpenAI `chat.completion` (`choices[].message`, `usage`) |
| 400 | unpriced model / malformed / unsupported feature | `{"error": …}` |
| 401 | unknown/missing/malformed token | `{"error":"unknown_run_token"}` |
| 402 | per-call cap or aggregate breach | `{"error":"spend_breach"}` |

## Metering parity assertions (broker-level tests — `inference_broker_openai_test.exs`)

1. Valid token + priced model + under cap → 200, ledger increments by exactly `micro_dollars(usage)`. (US2-1)
2. Missing / malformed / expired token → 401, **no** ledger change, **no** provider call. (US2-2)
3. Pre-existing `spent >= cap` → 402, provider never called. (US2-3)
4. Post-meter crossing → 402, kill-on-breach. (US2-3)
5. N sequential calls → exactly N ledger writes; sum reconciles call-for-call. (US2-4 / SC-003)
6. Native `/v1/inference` and `/v1/tool_calls` behaviour unchanged (regression). (US2-5 / FR-004)

## Invariants (must hold)

- No new gate authority. The surface meters; it does not grant. (Constitution XI)
- No change to `resolve/1` token semantics, `SpendLedger`, `InferencePrice`, `CredentialProxy`, or the native routes' handlers beyond the shared `read_http_request` header capture.
- Provider stubbing via `Application.get_env(:agent_os, :provider_fn)` works for the new path exactly as for the native path (Constitution IV — no live calls in tests).
