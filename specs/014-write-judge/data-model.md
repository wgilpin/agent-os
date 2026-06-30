# Data Model: Write the Judge

Describes the types, structures, and schemas used during test generation (Stage 3) and execution (Stage 6).

## Elixir Structs

### 1. `AgentOS.Pipeline.Stage3.TestCase`

Represents a single synthesized test scenario.

```elixir
defmodule AgentOS.Pipeline.Stage3.TestCase do
  @type t :: %__MODULE__{
          id: String.t(),
          input: map(),
          expected_behavior: String.t(),
          eval_prompt: String.t()
        }

  defstruct [:id, :input, :expected_behavior, :eval_prompt]
end
```

### 2. `AgentOS.Pipeline.Stage3.TestSpec`

The root structure of the `judge_spec.json` file.

```elixir
defmodule AgentOS.Pipeline.Stage3.TestSpec do
  alias AgentOS.Pipeline.Stage3.TestCase

  @type t :: %__MODULE__{
          agent_name: String.t(),
          purpose: String.t(),
          tests: [TestCase.t()]
        }

  defstruct [:agent_name, :purpose, :tests]
end
```

### 3. `AgentOS.Pipeline.Stage3.Verdict`

The verdict output returned after running the test spec.

```elixir
defmodule AgentOS.Pipeline.Stage3.Verdict do
  @type status :: :pass | :fail | :error

  @type t :: %__MODULE__{
          status: status(),
          reasoning: String.t(),
          disclaimer: String.t()
        }

  defstruct [:status, :reasoning, disclaimer: "Scope: CODE-MATCHES-MANIFEST. This does not verify human intent correctness."]
end
```

## State Store Schema: `"judge_results"`

A new collection is registered in the substrate `StateStore` mapping agent names to their latest execution verdict.

```elixir
# Store Name: "judge_results"
# Value structure:
%{
  agent_name => %{
    status: :unrun | :pass | :fail,
    last_run: DateTime.t() | nil,
    reasoning: String.t() | nil
  }
}
```

## JSON File Schema (`judge_spec.json`)

Serialized to disk at `agents/<agent_name>/judge_spec.json` for validation and programmatic runs.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "JudgeSpec",
  "type": "object",
  "properties": {
    "agent_name": { "type": "string" },
    "purpose": { "type": "string" },
    "tests": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id": { "type": "string" },
          "input": { "type": "object" },
          "expected_behavior": { "type": "string" },
          "eval_prompt": { "type": "string" }
        },
        "required": ["id", "input", "expected_behavior", "eval_prompt"]
      }
    }
  },
  "required": ["agent_name", "purpose", "tests"]
}
```
