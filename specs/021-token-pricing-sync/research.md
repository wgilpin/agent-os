# Research: Token Pricing Sync

## Precision and Unit Representation

### Decision
We will store token prices internally as **micro-dollars per million tokens** (equivalent to pico-dollars per token, i.e., $10^{-12}$ USD per token). The pricing metadata synced from OpenRouter (which is provided in USD per token) will be converted using decimal string parsing to avoid float rounding errors.

### Rationale
- **Sub-micro-dollar precision**: Modern models can cost as little as $0.07 per million tokens (0.07 micro-dollars per million tokens). Storing prices in integer micro-dollars per token would round these prices to `0` and make the models free, violating the fail-closed spend cap constraint. Storing prices in micro-dollars per million tokens preserves precision up to $0.00000001 (10^-8 USD) per token.
- **Exact integer math**: Calculations are performed in integer pico-dollars and then converted to micro-dollars using a safe rounding up division:
  $$\text{micro\_dollars} = \text{div}(\text{input\_tokens} \times \text{price.input} + \text{output\_tokens} \times \text{price.output} + 999\,999, 1\,000\,000)$$
  This guarantees that even a single token call for a sub-micro-dollar model is metered as at least 1 micro-dollar, completely closing any free call loopholes.

### Alternatives considered
1. **Float Representation**: Storing prices as floats. Rejected because floats introduce non-deterministic rounding errors in financial/metering calculations, which violates the requirement that the money path stay exact-integer.
2. **Micro-dollars per token**: Truncating or rounding to nearest integer micro-dollar per token. Rejected because it rounds cheap models to 0, which is a safety hole.

---

## Storage and Cache Architecture

### Decision
We will run a dedicated supervisor-managed GenServer (`AgentOS.InferencePriceSync`) that fetches OpenRouter prices at system boot and periodically refreshes them every 24 hours. The cache will be stored directly in the Elixir application environment using `Application.put_env(:agent_os, :inference_prices, prices)`.

### Rationale
- **Zero read overhead**: Reading from the application environment (`Application.get_env/2`) reads from a concurrent ETS table managed by Erlang's application controller. This requires no process message-passing overhead or synchronization bottlenecks in `InferenceBroker.complete/2`, preserving the requirement of sub-millisecond lookup times.
- **Fail-closed default**: If the GenServer fails to fetch pricing at boot, it logs a warning, falls back to the static `config.exs` prices, and does NOT overwrite the cache with empty values.

### Alternatives considered
1. **GenServer Cache State**: Querying a `Cache` GenServer for every inference request. Rejected because it introduces a process communication bottleneck in `complete/2`, violating performance constraints.
2. **ETS table directly**: Managed by the sync server. While extremely fast, `Application.put_env/3` uses ETS under the hood anyway and allows us to reuse the existing `Application.get_env/3` configuration pattern in `InferenceBroker.complete/2` with zero read-path changes.

---

## OpenRouter API Schema Parsing

### Decision
We will fetch from the public endpoint `https://openrouter.ai/api/v1/models` using the existing `Req` client (configured for the substrate). We will parse the response body, extract the `id`, `pricing.prompt`, and `pricing.completion` fields, and convert the decimal string values into micro-dollars per million tokens.

### Rationale
- **No authentication required**: The endpoint is public and does not require an API key, allowing sync at system boot before credentials are authenticated or decrypted.
- **Req Integration**: The substrate already uses `Req` for HTTP communication (as seen in `InferenceBroker` and elsewhere).
