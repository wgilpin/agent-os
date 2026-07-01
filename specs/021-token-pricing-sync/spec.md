# Feature Specification: Token Pricing Sync

**Feature Branch**: `021-token-pricing-sync`  
**Created**: 2026-07-01  
**Status**: Draft  
**Input**: User description: "Token Pricing Sync — dynamic model price lookups from OpenRouter for spend metering (roadmap 05-03, Phase 5)."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Dynamic Model Pricing Sync (Priority: P1)

As an agent host administrator, I want the system to dynamically populate and update the model price list from the upstream provider's catalog at runtime, so that spend metering always reflects current upstream costs without manual configuration changes.

**Why this priority**: This is the core capability that prevents manual price drift and allows new models to be metered automatically as soon as they are available.

**Independent Test**: Can be verified by booting the system with access to the upstream provider's public models catalog, and checking that the internal model price list is populated with correct per-token prices matching the provider's public registry.

**Acceptance Scenarios**:

1. **Given** the platform is starting up and the upstream pricing catalog is accessible, **When** the system boots, **Then** it retrieves the pricing metadata for all available models and loads them into the active prices cache.
2. **Given** a model's prices have been successfully synced, **When** an inference call is made against that model, **Then** the spend meter computes the call cost based on the newly synced rates rather than static file configurations.

---

### User Story 2 - Sub-Micro-Dollar Precision Metering (Priority: P1)

As an agent host administrator, I want the system to accurately meter calls to cheap models (costing less than 1 micro-dollar per token) without rounding errors or rounding down to zero, so that the spend limits cannot be bypassed by a high volume of low-cost requests.

**Why this priority**: Crucial safety constraint. If cheap models are rounded to 0 micro-dollars per token, they would effectively be metered as free, creating a major safety vulnerability.

**Independent Test**: Can be verified by configuring a mock price of 0.15 micro-dollars per token (i.e. $0.15 per million tokens) for a test model, making a small inference call, and confirming that the recorded spend is greater than zero and matches the exact proportional token consumption.

**Acceptance Scenarios**:

1. **Given** a cheap model with a price of $0.00000015 per token ($0.15 per million tokens), **When** an inference call is made with 1,000 input tokens and 0 output tokens, **Then** the spend ledger records a cost of exactly 150 micro-dollars.
2. **Given** a cheap model with a price of $0.00000015 per token ($0.15 per million tokens), **When** an inference call is made consuming a very small number of tokens (e.g. 1 token), **Then** the system rounds up to at least 1 micro-dollar to ensure the transaction is not free.

---

### User Story 3 - Fail-Closed Fallback (Priority: P2)

As an agent host administrator, I want the system to fall back to a safe offline price list if the upstream pricing API is down or returns invalid data, so that existing known models can still be safely metered and unknown models remain blocked.

**Why this priority**: System resilience. The agent host must remain operational for standard models even during external network outages, but it must never allow unpriced models to run.

**Independent Test**: Can be verified by blocking external access to the pricing API at boot, attempting to execute an inference request for a model in the fallback list, and confirming it succeeds and is metered correctly, while an unknown model is rejected.

**Acceptance Scenarios**:

1. **Given** the upstream pricing endpoint is unreachable during startup, **When** the system boots, **Then** it logs a warning, loads the offline fallback prices from config, and enters fallback mode.
2. **Given** the system is running in fallback mode, **When** an inference call is made for a model present in the fallback list, **Then** the request is allowed and metered using the fallback price.
3. **Given** the system is running in fallback mode, **When** an inference call is made for a model NOT in the fallback list, **Then** the request is blocked and returns an unpriced model error.

---

### Edge Cases

- **Partial Sync Failure / Malformed Upstream Data**: If the upstream API returns an incomplete list or invalid price formats (e.g., non-numeric strings), the system must reject the update, log a structured error, and retain the previous valid cache or fall back to the offline configuration.
- **Model price is 0**: If an upstream model is listed as free (price is 0), the system will treat it as a price of 0 (allow it, but meter as 0). However, if the price field is missing or invalid, it is treated as unpriced and blocked.
- **Intermittent Sync Outages**: If the system is running and a periodic refresh fails, the system must retain its currently cached runtime prices and log a warning, rather than clearing the cache or immediately switching back to older configuration defaults.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST fetch the public models list from the upstream provider's endpoint (`https://openrouter.ai/api/v1/models`) during the system boot sequence.
- **FR-002**: The system MUST support periodic updates of the model prices at runtime (defaulting to every 24 hours) without requiring a system restart.
- **FR-003**: The prices cache MUST be stored in memory behind the port boundary (substrate-side) and be concurrently readable by inference calls without process boundary bottlenecks.
- **FR-004**: The system MUST represent token pricing using **micro-dollars per million tokens** (equivalent to pico-dollars per token) to preserve precision for sub-micro-dollar prices.
- **FR-005**: The spend calculator MUST use integer-based arithmetic for all metering operations to avoid float rounding errors in the money path.
- **FR-006**: The cost calculation formula MUST round up to the nearest integer micro-dollar using the formula:
  $$\text{micro\_dollars} = \text{div}(\text{input\_tokens} \times \text{price.input} + \text{output\_tokens} \times \text{price.output} + 999\,999, 1\,000\,000)$$
  where price units are micro-dollars per million tokens.
- **FR-007**: Any model not present in the runtime pricing cache or the fallback configuration MUST be treated as unpriced and return an error (`{:error, :unpriced_model}`) to the calling agent, preventing the call from executing.
- **FR-008**: The system MUST support an offline fallback price list defined in the configuration, which is loaded when the dynamic sync fails or is disabled.

### Key Entities *(include if feature involves data)*

- **Model Price Entry**:
  - `model_id`: String (e.g., `"google/gemini-2.5-flash"`)
  - `input_price_per_million`: Non-negative integer (micro-dollars per million tokens)
  - `output_price_per_million`: Non-negative integer (micro-dollars per million tokens)
  - `source`: Atom (`:synced` or `:fallback`)
  - `updated_at`: DateTime

- **Prices Cache**:
  - A fast, concurrent, read-only key-value map mapping `model_id` to its `Model Price Entry`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Model prices can be synced from the upstream endpoint and updated in memory in under 3 seconds during system boot.
- **SC-002**: Calls to sub-micro-dollar models (e.g., $0.15 per million tokens) are metered with zero float rounding errors, and a 1-token call meters a non-zero cost (at least 1 micro-dollar) to prevent free execution leaks.
- **SC-003**: In the event of a total network outage at boot, the system starts successfully using the offline fallback list, allowing known models to execute and block unknown ones.
- **SC-004**: Dynamic price lookups add negligible overhead (less than 1 millisecond) to the total inference request duration.

## Assumptions

- **A-001**: OpenRouter's model pricing API (`https://openrouter.ai/api/v1/models`) does not require API key authentication, which allows the pricing sync to run before or independently of credential loading.
- **A-002**: The upstream provider returns prices in USD. Any currency conversion is out of scope.
- **A-003**: The dynamic pricing catalog is relatively small (hundreds of models), allowing it to easily fit in memory.
- **A-004**: The system's target environment has external network access to the provider's API under normal operations.
