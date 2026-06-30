# Walkthrough: Stage 1 Elicit Spec

We have successfully implemented and verified **Stage 1 (Elicit Spec)** of the v3 six-stage agent generation pipeline.

## 1. Summary of Changes

### Elixir Control Plane
- **`AgentOS.ElicitedSpec`**: Added a strongly-typed Elixir struct to hold the resolved, minimised specification (purpose, capability list, domain boundaries, spend limits, confirmed flag). Implements parsing/coercion logic from raw maps (JSON payload).
- **`AgentOS.ConversationSession`**: GenServer state structure holding conversational transcript and draft state. Supports serialization to/from JSON maps.
- **`AgentOS.ElicitationSession`**: Implements GenServer loop coordinating conversational turns, invoking the Python elicitor port process, verifying scope creep, and persisting the final confirmed spec to `elicited_spec.json`.
- **`Mix.Tasks.AgentOs.Elicit`**: mix task driving the interactive CLI conversation. Gracefully handles stream exhaustion (`:eof`).

### Python Workload
- **`agents/elicitor/models.py`**: Pydantic models strictly typing the spec, boundaries, spends, and elicitor responses.
- **`agents/elicitor/main.py`**: Executes structured JSON generation using Gemini API (with `gemini-3-flash-preview` and strict system instructions to enforce KISS/minimisation). Supports a deterministic mock path when `MOCK_ELICITOR=true` is set.
- **`agents/elicitor/test_main.py`**: Subprocess execution and unit test cases.

---

## 2. Verification Results

### Automated Tests

- **Python Tests**: Passed.
  ```bash
  uv run pytest agents/elicitor/test_main.py
  ```
- **Elixir Tests**: Passed (including mock elicitation lifecycle & scope creep checks).
  ```bash
  mix test test/agent_os/elicitation_test.exs
  ```
- **Whole Suite**: Checked that all 172 tests in the project compile and pass successfully.

### Manual Walkthrough

Running the mix task with mock elicitor:
```bash
echo -e "Gmail\nsave drafts\nyes\nyes" | MOCK_ELICITOR=true mix agent_os.elicit "reply to recruiter emails"
```
Produces:
```text
=== Agent OS Specification Elicitor ===
Purpose: "reply to recruiter emails"
Starting session...

[Elicitor] Which email service do you use? (e.g. Gmail)
User > 
[Elicitor] Should the agent send emails directly or just save drafts?
User > 
[Elicitor] Do you confirm this minimised specification?
User > 
=== Proposed Specification Summary ===
Purpose: reply to recruiter emails and save drafts
Capabilities: ["gmail_read", "gmail_draft"]
Boundaries:
  - Egress: ["gmail.googleapis.com"]
  - Target Locations: []
Spend Limits:
  - Dollar Cap: $0.05
  - Token Limit: 100000
=======================================
Do you confirm this specification? (yes/no) 
[Success] Elicited spec written to specs/012-elicit-spec/elicited_spec.json
```
And the resulting `elicited_spec.json` is successfully written.
