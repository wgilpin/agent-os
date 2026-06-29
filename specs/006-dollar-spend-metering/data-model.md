# Phase 1 Data Model: Dollar Spend Metering via an Inference Chokepoint

All dollar quantities are **integer micro-dollars** (1 unit = 1e-6 USD; FR-009). No floats anywhere
on the spend path.

---

## Inference Request (agent → broker)

The minimal payload the agent sends per model call. Carries no envelope data (FR-012, spec 003).

| Field | Type | Notes |
|-------|------|-------|
| `run_token` | `String.t()` | Substrate-issued per-run token (R2). Identifies the agent **server-side**; the agent never sets its own identity. |
| `model` | `String.t()` | Model id, e.g. `"gemini-3-flash-preview"`. Used to look up the price (R3). |
| `messages` | `[map()]` | The prompt / chat messages to forward to the provider. Opaque to metering. |

The agent sends **nothing else** — no cap, no price, no spend, no usage. Validation: unknown/expired
`run_token` ⇒ reject (fail closed); `model` absent from the price table ⇒ reject (fail closed,
FR-015).

## Inference Response (broker → agent)

| Case | Shape | Notes |
|------|-------|-------|
| Success | `%{completion: term()}` | Only the provider completion. No usage, price, cap, or spend (FR-002, Principle X). |
| Spend breach | `%{error: :spend_breach}` (HTTP 402/429) | Cap reached/crossed (pre-check or post-meter). Broker refuses inference (R5). |
| Unpriced model | `%{error: :unpriced_model}` (HTTP 4xx) | Fail-closed; provider not called (FR-015). |

## Provider Usage Record (provider → broker, ground truth)

Read from the provider's API response; the metered quantity. **Never** agent-supplied (FR-002).

| Field | Type | Notes |
|-------|------|-------|
| `input_tokens` | `non_neg_integer()` | Prompt tokens reported by the provider. |
| `output_tokens` | `non_neg_integer()` | Completion tokens reported by the provider. |
| `completion` | `term()` | The model output forwarded to the agent. |

In tests this is the canned payload returned by the injected `provider_fn` (R7) — no live call.
If a real response lacks usage, the broker treats it as fail-closed (cannot meter ⇒ does not pass
unmetered spend).

## Per-Model Price Entry (`Application` env `:inference_prices`)

| Field | Type | Notes |
|-------|------|-------|
| `input` | `pos_integer()` | Micro-dollars per **input** token. |
| `output` | `pos_integer()` | Micro-dollars per **output** token. |

Table shape: `%{model_id => %{input: micro_usd, output: micro_usd}}`. Owned by the control plane;
unreadable by the agent. Missing model ⇒ fail closed (FR-015).

**Metered dollars** for a call: `input_tokens * input + output_tokens * output` (integer
micro-dollars).

## Spend Ledger Entry (per agent) — REUSED from 005, unit reinterpreted

Persisted single-writer entry in `spend_ledger` (`data/spend_ledger.term`). **No schema change.**

| Field | Type | Notes |
|-------|------|-------|
| `spent` | `non_neg_integer()` | Cumulative **micro-dollars** in the current window — now the sum of inference dollars (broker) **and** per-action dollars (run-worker). Was arbitrary units in 005. |
| `window_start` | `DateTime.t()` | Window anchor (005). Reset + re-anchored by `SpendLedger.current_entry/3` when rolled over. |

Single source of truth for both enforcement (cap check) and visibility (operator render). Written
**only** via the `StateStore` single writer, by both `RunWorker` (post-gate action dollars) and the
`InferenceBroker` (per-call inference dollars) — one writer, two callers, no second store
(Principle IX).

## Spend Constraint (manifest) — REUSED from 005, unit reinterpreted

`%{cap, window, on_breach}` per agent. **Unchanged shape.**

| Field | Type | Notes |
|-------|------|-------|
| `cap` | `pos_integer()` | The per-window budget in **micro-dollars** (was arbitrary units). |
| `window` | `:daily` | Reused unchanged; only value in v2. |
| `on_breach` | `:kill` | Reused unchanged; only value in v2. |

The agent never reads the constraint (privileged-read, gate/broker only; Principle X).

## Per-Run Broker Token

| Field | Type | Notes |
|-------|------|-------|
| token value | `String.t()` | Opaque, substrate-generated per run, injected into the container env. |
| maps to | `{agent_name :: String.t(), manifest}` | Held server-side by the broker; resolves identity, cap, window. Invalidated when the run ends. |

## Connector Capability (registry) — `cost` re-denominated

`AgentOS.Connector` registry entry (002/004). **Only `cost` changes unit.**

| Field | Type | Notes |
|-------|------|-------|
| `cost` | `non_neg_integer()` | Per-action dollar cost in **micro-dollars** (was arbitrary units: kv_append=1, external_send=2). Free connectors ⇒ `0`; a connector with a real paid downstream call ⇒ that dollar cost. |
| (other fields) | — | `name`, `mutating?`, `requires_approval?`, `credential` unchanged. |

## Breach Stop Signal — REUSED from 005

`{:killed, :spend_breach}` returned by `RunWorker.run_once/1`; consumed by `RunSupervisor` as an
intentional stop (no restart). Reused unchanged; now also raised by the **inference-only** pre-gate
breach (zero actions), not just the action-cost breach.

---

## Relationships

```text
Inference Request --(run_token)--> Broker --resolve--> {agent_name, manifest(cap,window)}
                                     |
                       SpendLedger.current_entry (window reset, 005)
                                     |
                     pre-check: spent >= cap ? --> breach (refuse, flag run)
                                     | no
              CredentialProxy.with_credential(:model_key) -> provider_fn -> Usage Record
                                     |
                 dollars = in*input_price + out*output_price   (micro-dollars)
                                     |
                 StateStore put spend_ledger[agent] = spent + dollars   (single writer)
                                     |
                  post-meter: spent >= cap ? --> flag run breach (one-call overshoot)
                                     |
   RunWorker (run end): windowed spent >= cap ? --> dispatch_on_breach(:kill) -> {:killed, :spend_breach}
                       else gate actions; add per-action dollars to same spent; same cap
```
