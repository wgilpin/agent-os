# Data Model: Stage 5 Security Review Agent

This document defines the schema and structs for the security review verdict.

---

## 1. Elixir Structs

The struct `AgentOS.Pipeline.Stage5.Verdict` represents the recorded output of a security review check.

```elixir
defmodule AgentOS.Pipeline.Stage5.Verdict do
  @derive {Jason.Encoder, only: [:status, :reasoning, :timestamp]}
  @enforce_keys [:status, :reasoning, :timestamp]
  defstruct [:status, :reasoning, :timestamp]

  @type status :: :pass | :fail | :error

  @type t :: %__MODULE__{
          status: status(),
          reasoning: String.t(),
          timestamp: DateTime.t()
        }
end
```

---

## 2. StateStore Persistence Schema

The security review verdicts are stored in a single-writer GenServer StateStore process named `"security_review_results"`.

- **Registry Name**: `"security_review_results"`
- **File Path**: `data/security_review_results.term`
- **Shape**: Map of agent name (string) to `Verdict` struct.

```elixir
%{
  "recruiter_reply_agent" => %AgentOS.Pipeline.Stage5.Verdict{
    status: :pass,
    reasoning: "Code utilizes only allowed capabilities (external_send) and routes all model inference via UDS socket.",
    timestamp: ~U[2026-07-01 10:00:00Z]
  }
}
```

---

## 3. LLM JSON Response Schema

The security-review agent prompt instructs the model to return a structured JSON block matching this schema:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "SecurityReviewResponse",
  "type": "object",
  "properties": {
    "status": {
      "type": "string",
      "enum": ["pass", "fail"]
    },
    "reasoning": {
      "type": "string"
    }
  },
  "required": ["status", "reasoning"]
}
```
