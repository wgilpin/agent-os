# Research: Stage 2 Write the Manifest

This document outlines the technical research, mapping decisions, and architectural validation done to support deterministic manifest projection.

## Mapping Decisions

### 1. Spend Cap Mapping (Dollars to Micro-dollars)
- **Finding**: In `lib/agent_os/connector.ex`, costs are defined in micro-dollars (e.g. `2000` micro-dollars for `external_send`). In `lib/agent_os/manifest/spend.ex`, the spend cap is specified. `provisioner.ex` defaults to `100_000` micro-dollars ($0.10).
- **Decision**: Project `spend_limits.dollar_cap` from the spec to `spend.cap` in the manifest by multiplying by `1,000,000` and converting to an integer via `round/1`.

### 2. Boundary to Grant Constraints Mapping
- **Finding**: Manifest grants support `recipients` and `methods` lists. Elicited spec boundaries support `egress_domains` and `target_locations`.
- **Decision**: 
  - For `external_send`, map `boundaries.egress_domains` to `recipients` (sorted) and hardcode `methods: ["send"]`.
  - For `kv_append`, set `methods: ["append"]` and `recipients: nil`.
  - For other connectors (e.g., `gmail_read`, `gmail_draft`), default to `nil` for both since they do not have specific egress/target constraints mapped in this stage.

### 3. Non-Grant Structural Fields
- **Finding**: Manifest requires `owner`, `supervision`, `spend.window`, and `spend.on_breach`. Spec does not contain these.
- **Decision**: Use the strictest constants:
  - `owner`: `"human"`
  - `supervision`: `"restart-once-and-alert"`
  - `spend.window`: `:daily`
  - `spend.on_breach`: `:kill`

## Alternatives Considered

- **Using LLM for projection**: Rejected due to Principle I (Simplicity First) and the requirement for pure determinism. A pure function is 100% reliable, fast, and does not leak or drift.
- **Raising error on all missing boundary mappings**: Rejected. Since KV/Gmail does not currently require boundaries at the v2 gate, raising errors for them would make the projection unusable for standard templates.
