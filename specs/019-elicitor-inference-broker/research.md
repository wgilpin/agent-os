# Research: Routing Elicitor through Inference Broker

## Key Decision: Metering Identity for Pre-Manifest Elicitation

### Options Considered:
1. **Reserved `"elicitor"` Agent Identity** (Chosen):
   - **Mechanism**: The `ElicitationSession` generates a dynamic `run_token` and registers it with `InferenceBroker.register(token, "elicitor", manifest)` where `manifest` is a dynamically constructed system manifest for elicitation.
   - **Rationale**: Keeps the central invariant of the broker completely intact. Every inference call is metered against an agent name and a manifest cap. The spend is accumulated in the spend ledger under `"elicitor"`, enforcing a unified onboarding cap.
   - **Alternatives**: Using a single global static token (e.g. `"system"`). This is less secure as it doesn't allow session isolation.

2. **Explicit Unmetered "System Lane"**:
   - **Mechanism**: Add a special case to the broker that allows bypass if the token is `"system"`.
   - **Rationale**: Rejected. This violates the engineering and security invariant that everything is metered and all credentials flow through the same cap-enforced chokepoint.

## Python UDS Transport Implementation

### Reference: `agents/discovery/main.py`
The discovery agent connects to `$INFERENCE_SOCKET` and makes a stream-based HTTP POST request to `/v1/inference`.
We will extract this logic into a simple `call_inference_broker` helper in `agents/elicitor/main.py`.

### Elicitor Payload & Parsing
- **UDS Response Format**: The broker returns `{"completion": "<string content>"}`.
- **Urllib Dependency**: Completely removed from `run_live` in `agents/elicitor/main.py`.
- **Credential**: `MODEL_KEY` is no longer loaded or validated in Python.

## Test Seam for UDS Broker Mocking

To ensure the test suite never contacts the live OpenRouter API, we must mock the inference provider at the `InferenceBroker` level during tests.
Since UDS tasks call `InferenceBroker.complete/1` (which does not accept options), we will support an application environment override:
`Application.get_env(:agent_os, :provider_fn)`
This allows the test suite to configure a global mock provider function, ensuring UDS socket calls from Python workloads return canned responses deterministically in tests.
