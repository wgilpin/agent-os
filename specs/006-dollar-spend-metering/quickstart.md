# Quickstart: Dollar Spend Metering via an Inference Chokepoint

How to exercise the feature deterministically — no live LLM, no network, no Docker (Constitution
IV). All dollars are integer micro-dollars.

## Prerequisites

- A fixed price table in test config, e.g.
  `config :agent_os, :inference_prices, %{"mock-model" => %{input: 10, output: 30}}`
  (10 µ$/input token, 30 µ$/output token).
- A small cap in the manifest/seed, e.g. `cap: 1000` µ$ ( = $0.001).
- The inference credential present in test config: `credentials: %{model_key: "test_...", ...}`.
- A mock provider fn returning a canned usage payload, e.g.
  `provider_fn = fn _model, _messages, _secret -> %{input_tokens: 20, output_tokens: 10, completion: "hi"} end`
  → metered dollars `= 20*10 + 10*30 = 500` µ$ per call.

## 1. Meter an inference call (SC-001, US1)

```elixir
req = %{run_token: token, model: "mock-model", messages: [%{role: "user", content: "x"}]}
{:ok, %{completion: "hi"}} =
  AgentOS.InferenceBroker.complete(req, now: t0, provider_fn: provider_fn)

# ledger now holds 500 µ$ for this agent; result carries ONLY :completion
%{spent: 500} = StateStore.snapshot("spend_ledger") |> Map.get(agent_name)
```

Assert the result has no `:price`, `:cap`, `:usage`, or `:spent` key (FR-002, Principle X).

## 2. Runaway loop killed with zero actions (SC-002, US2)

```elixir
# Two calls at 500 µ$ reach the 1000 µ$ cap → the second crosses.
{:ok, _} = InferenceBroker.complete(req, now: t0, provider_fn: provider_fn)   # spent 500
{:breach, :spend} = InferenceBroker.complete(req, now: t0, provider_fn: provider_fn)  # spent 1000 ≥ cap
{:breach, :spend} = InferenceBroker.complete(req, now: t0, provider_fn: provider_fn)  # refused (pre-check)

# A run with ZERO proposed actions is still killed because windowed spent ≥ cap:
{:killed, :spend_breach} =
  RunWorker.run_once(agent_cmd: "python", agent_args: [...], items: [], now: t0, manifest_path: m)
# RunSupervisor does NOT restart it (005 restart-exemption).
```

## 3. Combined budget — inference + per-action dollars, one cap (SC-003, US3)

```elixir
# Seed inference spend below cap, then a run whose approved action dollars push the
# SAME `spent` over the SAME cap → killed.
StateStore.apply_action("spend_ledger", {:put, agent_name, %{spent: 600, window_start: t0}})
{:killed, :spend_breach} = RunWorker.run_once(items: [...over-cap action...], now: t0, ...)
```

## 4. Window reset in dollars (SC-004, US4)

```elixir
# Advance the injected clock past the daily boundary → spent resets to 0.
t1 = DateTime.add(t0, 86_400, :second)
{:ok, _} = InferenceBroker.complete(req, now: t1, provider_fn: provider_fn)
%{spent: 500, window_start: ^t1} = StateStore.snapshot("spend_ledger") |> Map.get(agent_name)
```

## 5. Fail-closed on a missing price (FR-015)

```elixir
{:error, :unpriced_model} =
  InferenceBroker.complete(%{req | model: "no-price-model"}, now: t0, provider_fn: provider_fn)
# provider_fn was NOT called; nothing metered; the agent cannot evade the meter.
```

## 6. Dollar visibility (SC-005, US4)

```elixir
# After some metered spend, the standing inventory shows spent/cap/window in DOLLARS,
# read from the persisted ledger — never from the agent.
output = AgentOS.Inventory.render(now: t0)
assert output =~ "$0.0005 / $0.001"   # 500 µ$ / 1000 µ$, formatted
```

## What is NOT tested (per Constitution III/IV)

- The live UDS transport and the Python inference shim — manual walkthrough / integration only.
- Any live provider call — the `provider_fn` is always mocked.
