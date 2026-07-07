# Research: Priorities Coach E2E Generation

## Context
This phase is primarily a glue and proof phase (10-04) that validates the capabilities implemented in 10-01, 10-02, and 10-03. The core goal is ensuring the manifest projection can successfully emit the new grant shapes and that the Gate enforces them correctly.

## Findings
- **Trigger Combination**: We need to ensure that the `Pipeline`'s projection prompt or logic can output an agent with both a `%{type: :message}` trigger and a daily scheduled time trigger.
- **Grant Combination**: The projection must correctly emit `file_read`/`file_write` (path grant) and `discord_notify` (static credential) along with a spend cap.
- **Testing Approach**: Re-use `world_b_generated_test.exs` by feeding it the generated coach manifest. Stub out the models and effectors to run generation locally without network calls.

## Decisions
- **Decision**: No new architectural logic required.
- **Rationale**: The substrate's existing pipeline is robust enough. The focus is entirely on verifying the integration and that the new grants are parsed and enforced.
