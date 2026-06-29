# Contract: `AgentOS.InferenceBroker`

The substrate-side inference chokepoint. Meters each model call into dollars, enforces the cap
per call, and is the sole holder of the inference key. Pure-ish core (`complete/2`) is driven
directly by the deterministic test suite with an injected mock provider (Constitution IV).

All dollar values are **integer micro-dollars** (FR-009).

## `complete/2`

```elixir
@type request :: %{run_token: String.t(), model: String.t(), messages: [map()]}
@type usage :: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer(), completion: term()}
@type result ::
        {:ok, %{completion: term()}}
        | {:breach, :spend}
        | {:error, :unpriced_model | :unknown_run_token | :missing_usage}

@spec complete(request(), opts :: keyword()) :: result()
```

**`opts`** (all injectable for determinism):
- `:now` — `DateTime.t()`, default `DateTime.utc_now/0` (window math, reuses 005).
- `:provider_fn` — `(model, messages, secret -> usage())`, default the real Gemini 3-series client.
  Tests inject a fn returning a canned `usage()`; **no live LLM** (R7).
- `:prices` — price table, default `Application.get_env(:agent_os, :inference_prices)`.

### Algorithm (R5 — per-call meter + cap)

1. Resolve `run_token → {agent_name, manifest}` server-side. Unknown ⇒ `{:error, :unknown_run_token}`
   (fail closed; agent cannot spoof identity, R2).
2. Look up `prices[model]`. Missing ⇒ `{:error, :unpriced_model}` (fail closed, FR-015) — provider
   **not** called.
3. Read the agent's `spend_ledger` entry; normalise with `SpendLedger.current_entry(entry, now,
   manifest.spend.window)` (window reset, 005). Persist the reset if it changed.
4. **Pre-check**: `if spent >= cap ⇒ {:breach, :spend}` — provider **not** called (R5 step 2).
5. Call provider: `CredentialProxy.with_credential(:model_key, fn secret -> provider_fn.(model,
   messages, secret) end)`. Missing usage ⇒ `{:error, :missing_usage}` (fail closed).
6. `dollars = usage.input_tokens * prices[model].input + usage.output_tokens * prices[model].output`.
7. Persist `spend_ledger[agent_name] = %{entry | spent: spent + dollars}` via the `StateStore`
   single writer (Principle IX).
8. **Post-meter check**: `if spent + dollars >= cap ⇒ {:breach, :spend}` (the crossing call is
   metered and counted — one-call overshoot, no pre-estimation). Else `{:ok, %{completion:
   usage.completion}}`.

### Guarantees

- The agent never receives usage, price, cap, or spend — only `completion` or an opaque error
  (FR-002, Principle X).
- The metered quantity is provider-reported tokens × config price; never agent-supplied (FR-002).
- On any `{:breach, :spend}` or fail-closed error, **no completion is returned** and the run is
  flagged for kill; subsequent calls in the same run re-hit the pre-check and also breach (the
  bill stops the instant the cap is crossed, FR-014).
- The inference key `:model_key` is resolved only inside `with_credential` and never returned,
  logged, or persisted (004 invariant).

### Test obligations (`inference_broker_test.exs`)

- Price math: canned `usage` × fixed price ⇒ exact micro-dollars summed into the ledger (SC-001).
- Pre-check breach: `spent` already at cap ⇒ `{:breach, :spend}`, `provider_fn` **not** invoked.
- Post-meter breach + one-call overshoot: a call that crosses ⇒ metered, `{:breach, :spend}`, final
  `spent` exceeds cap by exactly that call's cost.
- Fail-closed: unpriced model ⇒ `{:error, :unpriced_model}`, provider not called; unknown token ⇒
  `{:error, :unknown_run_token}`.
- Invisibility: assert the success result contains only `:completion`; no price/cap/usage/spent key.
- Determinism: all of the above with an injected `:now`, fixed `:prices`, mock `:provider_fn`.
