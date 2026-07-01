# Quickstart: Token Pricing Sync

This guide explains how to verify and run the dynamic token pricing sync system.

## 1. Verify Active Configuration
The dynamic sync runs automatically at startup and does not require an API key because the OpenRouter models catalog is a public endpoint.

To verify fallback configuration:
- In `config/config.exs`, make sure `inference_prices` contains the fallback prices represented as micro-dollars per million tokens (equivalent to pico-dollars per token):
  ```elixir
  config :agent_os,
    inference_prices: %{
      "google/gemini-2.5-flash" => %{input: 75_000_000, output: 250_000_000}
    }
  ```

---

## 2. Boot Logging and Status Diagnostics
When the system starts up, it attempts to fetch pricing from OpenRouter:

### Happy Path (Network Available)
```text
18:00:00.000 [info] InferencePriceSync: Successfully synced pricing for 124 models from OpenRouter.
```

### Fallback Path (Network Down / API Error)
```text
18:00:00.000 [warning] InferencePriceSync: Failed to fetch models pricing from OpenRouter: :nxdomain. Falling back to configured static prices.
```

---

## 3. Dynamic Price Verification
You can inspect the currently loaded pricing cache from the Elixir shell (`iex`):

```elixir
# Retrieve the active price entries
prices = Application.get_env(:agent_os, :inference_prices)

# Inspect the pricing for a specific model (e.g. Gemini 2.5 Flash)
Map.get(prices, "google/gemini-2.5-flash")
# => %{input: 75000000, output: 250000000}
```
