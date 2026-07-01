# Data Model: Token Pricing Sync

This document defines the data structures and validations for the dynamic model token pricing system.

## Entities

### 1. ModelPrice (Schema/Struct)
Represents the priced token rates for a specific model.

*   **`model_id`** (String): Unique identifier of the model (e.g., `"google/gemini-2.5-flash"`). Must not be empty or blank.
*   **`input_price_per_million`** (Integer): Price per 1,000,000 input tokens in micro-dollars. Must be a non-negative integer.
*   **`output_price_per_million`** (Integer): Price per 1,000,000 output tokens in micro-dollars. Must be a non-negative integer.
*   **`source`** (Atom): The source of the pricing data. Either `:synced` or `:fallback`.
*   **`updated_at`** (DateTime): Timestamp when the entry was written/updated in the cache.

### 2. Prices Cache (State)
The global in-memory lookup table mapping model identifiers to their pricing information.

*   **Type**: `%{String.t() => ModelPrice.t()}`
*   **Storage**: Cached via the Elixir application environment (`:agent_os`, `:inference_prices`).
*   **Access**: Concurrent, read-only path via `AgentOS.InferencePrice.lookup/2`.

---

## Validation and Scaling Rules

### Decimal to Integer Conversion
To convert upstream decimal string prices (USD per token) to micro-dollars per million tokens (pico-dollars per token) without float operations:

1.  **Parse Integer/Fractional Parts**:
    *   Split the string on `"."`.
    *   If no decimal point is present, the fractional part is empty.
2.  **Align to 12 Decimal Places**:
    *   Truncate the fractional part if it exceeds 12 digits.
    *   Pad the fractional part with trailing `"0"`s if it is shorter than 12 digits.
3.  **Calculate Total Value**:
    *   $\text{Value} = \text{IntegerPart} \times 10^{12} + \text{FractionalPart}$.
    *   This represents the price in pico-dollars per token, which is exactly equivalent to micro-dollars per million tokens.

---

## State Transitions

```mermaid
state-diagram
  [*] --> OfflineFallback : Boot (Default Config loaded)
  OfflineFallback --> SyncedCache : Start-up Fetch Succeeded (Cache replaced)
  OfflineFallback --> OfflineFallback : Start-up Fetch Failed (Retains default config)
  SyncedCache --> SyncedCache : Periodic Refresh Succeeded (Cache updated)
  SyncedCache --> SyncedCache : Periodic Refresh Failed (Retains current cache + log warning)
```
