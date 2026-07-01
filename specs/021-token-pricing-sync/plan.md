# Implementation Plan: Token Pricing Sync

**Branch**: `021-token-pricing-sync` | **Date**: 2026-07-01 | **Spec**: [spec.md](file:///Users/will/projects/agent_os/specs/021-token-pricing-sync/spec.md)
**Input**: Feature specification from `/specs/021-token-pricing-sync/spec.md`

## Summary
The goal of this feature is to dynamically fetch, scale, cache, and refresh OpenRouter model pricing on the substrate side of AgentOS. Pricing will be fetched from the public endpoint `https://openrouter.ai/api/v1/models` at startup and every 24 hours. The cost calculations will be updated to use micro-dollars per million tokens (pico-dollars per token) to prevent cheap models from rounding to 0. Fallback prices will be used when the API is down.

## Technical Context
**Language/Version**: Elixir 1.15+ (OTP 26)
**Primary Dependencies**: `Req` (already in lockfile)
**Storage**: Memory cache via application environment (`Application.put_env/3` / `Application.get_env/3`), configuration for offline fallback.
**Testing**: ExUnit (run via `mix test`)
**Target Platform**: BEAM / Host Substrate
**Project Type**: Elixir OTP Substrate Service
**Performance Goals**: Dynamic lookup under 1ms (direct ETS read via `Application.get_env/3` is <10 microseconds).
**Constraints**: exact-integer math in the money path, fail-closed spend caps, zero live dependencies in tests.
**Scale/Scope**: ~150-250 models loaded at boot.

## Constitution Check
*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Simplicity First (Pass)**: Uses the standard application controller/environment for cache storage instead of a custom database or complex state management.
- **IV. No Live Dependencies in Tests (Pass)**: All API calls to OpenRouter in tests will be mocked using the test options context `provider_fn` or `Req` stubs, asserting deterministic math.
- **V. Strong Typing (Pass)**: All fields are typed. Elixir price lookup and calculation functions will use typespecs.
- **IX. The Substrate Owns State & Lifecycle (Pass)**: The prices synced from OpenRouter are stored in the substrate's state and never reach sandboxed agent workloads.

## Project Structure
### Documentation (this feature)
```text
specs/021-token-pricing-sync/
├── plan.md              # This file
├── research.md          # Research findings on units and caching
├── data-model.md        # Data entities, validation rules, state transitions
├── quickstart.md        # Verifying configurations, logs, and cache state
└── contracts/
    └── openrouter-models-api.md  # API contract for pricing endpoint
```

### Source Code (repository root)
```text
config/
├── config.exs           # Modify fallback pricing values

lib/agent_os/
├── application.ex       # Start InferencePriceSync in supervisor
├── inference_broker.ex  # Update complete/2 math to use new precision scale
├── inference_price.ex   # Update price_entry/lookup/micro_dollars types/math
└── inference_price_sync.ex  # [NEW] GenServer for boot sync and periodic fetch

test/agent_os/
├── inference_price_sync_test.exs  # [NEW] Test boot fetch, periodic refresh, mock API responses, fallback logic
└── inference_broker_test.exs      # Update mock pricing values to new scale
```

**Structure Decision**: Standard single Elixir project structure. Modifying `InferenceBroker` and `InferencePrice` in place, adding `InferencePriceSync` GenServer and its unit tests.

## Proposed Changes

### Configuration & Application

#### [MODIFY] [config.exs](file:///Users/will/projects/agent_os/config/config.exs)
- Update standard default pricing for `"google/gemini-2.5-flash"` to `%{input: 75_000_000, output: 250_000_000}` (micro-dollars per million tokens).
- Update test environment `inference_prices` in the `if config_env() == :test do` block to use the scaled rates: e.g. `mock-model` -> `%{input: 10_000_000, output: 30_000_000}`.

#### [MODIFY] [application.ex](file:///Users/will/projects/agent_os/lib/agent_os/application.ex)
- Add `{AgentOS.InferencePriceSync, []}` to the supervision tree `children` list when `:autostart` is true.

### Core Inference Logic

#### [MODIFY] [inference_price.ex](file:///Users/will/projects/agent_os/lib/agent_os/inference_price.ex)
- Update `@type price_entry` typespec to match scaled integer schema.
- Update `micro_dollars/2` function to do scaled integer math (inputs in pico-dollars/token, output rounded up to micro-dollars).

#### [MODIFY] [inference_broker.ex](file:///Users/will/projects/agent_os/lib/agent_os/inference_broker.ex)
- Ensure pricing check works properly with updated types/structure.

### Pricing Synchronization Service

#### [NEW] [inference_price_sync.ex](file:///Users/will/projects/agent_os/lib/agent_os/inference_price_sync.ex)
- Implement `AgentOS.InferencePriceSync` GenServer.
- On startup (`init/1` via `handle_continue/2` or startup message), attempt to fetch OpenRouter's model pricing list.
- Parse standard model structures, scale price prompt/completion to integers, merge with existing config env fallback prices, and update the environment variable `:inference_prices`.
- Schedule a refresh message using `Process.send_after/3` to trigger a re-sync every 24 hours.

## Verification Plan

### Automated Tests
- Run `mix test test/agent_os/inference_broker_test.exs` to ensure existing checks pass under the updated scale.
- Run `mix test test/agent_os/inference_price_sync_test.exs` to verify:
  1. Parsing logic: decimal strings like `"0.00000015"` convert correctly to `150_000`.
  2. Happy path sync: merges API responses into `inference_prices` cache.
  3. Failure fallback: when the API endpoint returns errors, fallbacks remain unchanged and warning logs are emitted.
  4. Periodic sync triggers are scheduled.

### Manual Verification
- Run the system with network enabled: confirm successful boot sync log messages.
- Run the system with network disabled (or pointing to an invalid port/host): confirm fallback warning logs and check that the static fallback prices are still loaded and queryable.
