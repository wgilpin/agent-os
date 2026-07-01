# API Contract: Stage 5 Security Review Agent

This document defines the interface and validation guards for the Stage 5 security review agent.

---

## 1. Programmatic Interface

The primary entry point is `AgentOS.Pipeline.Stage5.review/3` (with an optional 4th argument for testing/seams).

```elixir
defmodule AgentOS.Pipeline.Stage5 do
  @doc """
  Runs the security-review LLM agent to inspect the generated code against the manifest and purpose.
  
  Returns `{:ok, verdict}` or `{:error, reason}`.
  """
  @spec review(
          agent_name :: String.t(),
          manifest :: AgentOS.Manifest.t(),
          code_files :: %{String.t() => String.t()},
          opts :: Keyword.t()
        ) :: {:ok, AgentOS.Pipeline.Stage5.Verdict.t()} | {:error, any()}
  def review(agent_name, manifest, code_files, opts \\ []) do
    # ...
  end
end
```

---

## 2. Validation & Execution Pipeline

The `review/3` function must execute sequentially, short-circuiting on the first failure:

```mermaid
graph TD
    Start[Call review/3] --> V1[Validate code_files contains main.py and models.py]
    V1 -- Yes --> V2[Validate run_token exists in opts]
    V1 -- No --> FailClosed[Return {:error, :missing_required_files}]
    V2 -- Yes --> V3[Formulate Hardened Messages]
    V2 -- No --> FailClosed2[Return {:error, :missing_run_token}]
    V3 --> V4[Invoke InferenceBroker.complete/3]
    V4 -- Success --> V5[Parse JSON response]
    V4 -- Failure/Timeout/Breach --> FailClosed3[Return {:error, reason}]
    V5 -- Valid --> V6[Persist Verdict to StateStore]
    V5 -- Invalid JSON --> FailClosed4[Return {:error, :invalid_review_format}]
    V6 --> Return[Return {:ok, Verdict}]
```

---

## 3. Guard Details

1. **Required Files Guard**: `code_files` must have binary keys `"main.py"` and `"models.py"`. If missing, fail closed immediately without calling the broker.
2. **Missing Run Token Guard**: Ensure `:run_token` is present in `opts`. If missing, fail closed immediately without calling the broker.
3. **Broker Fail-Closed Guard**: Any result from the `InferenceBroker` that is not `{:ok, completion_map}` (e.g. `{:breach, :spend}`, `{:error, :timeout}`) is immediately mapped to `{:error, reason}` and fails the review run.
4. **Format Validation Guard**: If the completion string cannot be parsed as JSON or does not contain keys `"status"` and `"reasoning"`, return `{:error, :invalid_review_format}`.
