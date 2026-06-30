# Research: Stage 1 Elicit Spec

## 1. Architectural Alignment & Technology Stack

The Agent OS architecture splits the system into a deterministic BEAM/OTP control plane (the kernel) and containerized Python workloads for non-deterministic LLM agent tasks. The Elicit Spec phase must follow this split.

### Decision: Elixir Control Plane with a Python Elicitor Workload
- **Elicitation Orchestration (Elixir)**:
  A GenServer or CLI driver in Elixir coordinates the session. It manages the persistent state of the conversation (transcript, spec draft) using standard files. It launches the Python Elicitor Agent via ports, passing the current conversation state and receiving back proposed clarifications or a draft spec.
- **Elicitor LLM Logic (Python)**:
  A Python script using Pydantic and the Gemini SDK (3-series model) that parses user inputs, checks them against KISS/minimisation constraints, identifies candidate capabilities (triggers, connectors, domains, spend), and formats questions.

### Rationale
- **Principle IX (The Substrate Owns State & Lifecycle)**: Session lifecycle, files, and user prompts are owned by the BEAM substrate. The Python agent remains invocation-scoped (it parses a history, performs a inference step, and returns JSON, then terminates).
- **Principle V (Strong Typing)**: Using Pydantic models in Python allows us to strictly type the JSON output structure returned to Elixir, ensuring `mypy` type-safety. On the Elixir side, we parse the JSON into an `AgentOS.ElicitedSpec` struct with Dialyzer typespecs.

### Alternatives Considered
- **Pure Elixir Orchestration with raw Gemini API**: Rejected. Pydantic is extremely mature for structured JSON schema extraction and validation. Building this in Elixir would require parsing complex JSON, validating schemas manually, and would be less robust for prompt-driven structuring.
- **Pure Python Elicitation CLI**: Rejected. If Python owns the CLI and state, it violates the substrate-ownership principle and bypasses the control plane's supervising architecture.

---

## 2. Elicited Spec Data Schema

### Decision: Strict JSON Schema + Elixir Struct representation
The structured spec output of Stage 1 will be saved as `specs/<feature-name>/elicited_spec.json`.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "ElicitedSpec",
  "type": "object",
  "properties": {
    "purpose": { "type": "string" },
    "capabilities": {
      "type": "array",
      "items": { "type": "string" }
    },
    "boundaries": {
      "type": "object",
      "properties": {
        "egress_domains": {
          "type": "array",
          "items": { "type": "string" }
        },
        "target_locations": {
          "type": "array",
          "items": { "type": "string" }
        }
      },
      "required": ["egress_domains", "target_locations"]
    },
    "spend_limits": {
      "type": "object",
      "properties": {
        "dollar_cap": { "type": "number" },
        "token_limit": { "type": "integer" }
      },
      "required": ["dollar_cap", "token_limit"]
    },
    "confirmed": { "type": "boolean" }
  },
  "required": ["purpose", "capabilities", "boundaries", "spend_limits", "confirmed"]
}
```

### Rationale
- **Principle V (Strong Typing)**: Prevents raw maps/blobs.
- Provides a clean, unambiguous contract for Stage 2 (manifest generation) to map capabilities deterministically to the actual manifest MD.

---

## 3. Conversation Interface & KISS Enforcement

### Decision: Interactive Prompt-Response Loop with Proactive KISS Auditing
The Python Elicitor Agent will be instructed to perform a "KISS check" on the purpose and requested capabilities. It compares the stated purpose with the list of standard capabilities available in the Agent OS connector registry.
If the user requests something outside the minimum set needed to solve the purpose, the LLM prompt returns a flag `scope_creep: true` and a pushback message instead of confirming the spec.

### Rationale
- **Principle I (Simplicity First) & II (Explicit Scope Control)**: Ensures the orchestrator pushes back on scope creep natively in the conversational flow, prompting for confirmation only when the proposed spec is KISS-clear.
