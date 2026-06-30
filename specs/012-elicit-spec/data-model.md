# Data Model: Stage 1 Elicit Spec

## 1. Elixir Structs

### `AgentOS.ElicitedSpec`
Represents the strongly-typed, finalized specification.

```elixir
defmodule AgentOS.ElicitedSpec do
  @type t :: %__MODULE__{
    purpose: String.t(),
    capabilities: [String.t()],
    boundaries: %{
      egress_domains: [String.t()],
      target_locations: [String.t()]
    },
    spend_limits: %{
      dollar_cap: float(),
      token_limit: integer()
    },
    confirmed: boolean()
  }

  defstruct [
    :purpose,
    :capabilities,
    boundaries: %{egress_domains: [], target_locations: []},
    spend_limits: %{dollar_cap: 0.0, token_limit: 0},
    confirmed: false
  ]
end
```

### `AgentOS.ConversationSession`
Manages the active in-memory or persisted conversation state.

```elixir
defmodule AgentOS.ConversationSession do
  @type message :: %{
    role: :user | :assistant | :system,
    content: String.t(),
    timestamp: DateTime.t()
  }

  @type t :: %__MODULE__{
    session_id: String.t(),
    original_purpose: String.t(),
    transcript: [message()],
    spec_draft: AgentOS.ElicitedSpec.t() | nil,
    status: :active | :confirmed | :cancelled
  }

  defstruct [:session_id, :original_purpose, transcript: [], spec_draft: nil, status: :active]
end
```

---

## 2. Python Pydantic Models

Used by the Python Elicitor workload to structure LLM outputs.

```python
from typing import List, Dict
from pydantic import BaseModel, Field

class BoundaryModel(BaseModel):
    egress_domains: List[str] = Field(description="Allowed outgoing domain hosts, e.g. ['api.github.com']")
    target_locations: List[str] = Field(description="Allowed storage paths or folders, e.g. ['data/inventory.term']")

class SpendLimitsModel(BaseModel):
    dollar_cap: float = Field(description="Maximum dollar-denominated spend cap, e.g. 0.50")
    token_limit: int = Field(description="Maximum total tokens allowed per execution run")

class ElicitedSpecModel(BaseModel):
    purpose: str = Field(description="Concise description of the agent's goal")
    capabilities: List[str] = Field(description="Minimal set of connector capability grants")
    boundaries: BoundaryModel
    spend_limits: SpendLimitsModel
    confirmed: bool = Field(description="Whether the user has explicitly confirmed the spec")

class ElicitorResponse(BaseModel):
    spec_draft: ElicitedSpecModel
    next_question: str = Field(description="The next clarifying question to ask the user, or empty if KISS-clear and ready to confirm")
    scope_creep_detected: bool = Field(description="Whether the user is trying to add unnecessary permissions")
    pushback_message: str = Field(description="Warning message to show the user if scope creep is detected, otherwise empty")
```
