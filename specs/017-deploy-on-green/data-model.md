# Data Model: Stage 6 Deploy-on-Green

## State Store Schema: `"provenance"`

The existing `provenance` store is updated to record co-generated verdicts and failure reasons alongside deployment status.

```elixir
# Store Name: "provenance"
# Value structure:
%{
  agent_name => %{
    status: :failed | :reviewed_human | :skipped_in_envelope | :dangerously_skipped | :blocked,
    hash: String.t(), # SHA-256 hash of the manifest file
    judge_verdict: :pass | :fail | :error | :unrun,
    security_verdict: :pass | :fail | :error | :unrun,
    failure_reason: :judge_failed | :security_review_failed | :both_failed | :missing_verdict | :stale_verdict | nil
  }
}
```

## State Store Schema updates: `"judge_results"` & `"security_review_results"`

To support detection of "stale verdicts" (where the code was regenerated after tests or reviews were run), both verdict stores persist the SHA-256 hash of the co-generated code files (`main.py` + `models.py`) they evaluated.

### `"judge_results"` update
```elixir
%{
  agent_name => %{
    status: :unrun | :pass | :fail,
    last_run: DateTime.t() | nil,
    reasoning: String.t() | nil,
    code_hash: String.t() | nil # SHA-256 code hash
  }
}
```

### `"security_review_results"` update
The `AgentOS.Pipeline.Stage5.Verdict` struct is updated:
```elixir
defmodule AgentOS.Pipeline.Stage5.Verdict do
  defstruct [:status, :reasoning, :timestamp, :code_hash]
end
```
Which is persisted directly in `"security_review_results"`:
```elixir
%{
  agent_name => %AgentOS.Pipeline.Stage5.Verdict{
    status: :pass | :fail | :error,
    reasoning: String.t(),
    timestamp: DateTime.t(),
    code_hash: String.t() # SHA-256 code hash
  }
}
```
