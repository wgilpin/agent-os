# Contract: Judge Generator & Runner API

Defines the program interfaces for synthesizing the test spec and executing the LLM-as-judge compliance evaluations.

## Public Elixir API

```elixir
defmodule AgentOS.Pipeline.Stage3 do
  alias AgentOS.Manifest
  alias AgentOS.Pipeline.Stage3.{TestSpec, Verdict}

  @doc """
  Stage 3 entrypoint: Synthesizes a test specification (`judge_spec.json`)
  from a confirmed manifest and raw purpose string.
  
  Routes LLM calls to generate the test cases through AgentOS.InferenceBroker.
  Saves the output to `agents/<agent_name>/judge_spec.json`.
  """
  @spec generate(String.t(), Manifest.t(), keyword()) :: {:ok, TestSpec.t()} | {:error, any()}
  def generate(agent_name, manifest, opts \\ [])

  @doc """
  Stage 6 / Deploy-time entrypoint: Executes the synthesized test spec
  against the generated agent. 
  
  Launches the agent in a sandboxed runner, intercepting its output/proposed actions,
  and evaluates compliance using the InferenceBroker (LLM-as-judge).
  
  Updates the "judge_results" StateStore collection and returns the final verdict.
  """
  @spec run(String.t(), keyword()) :: {:ok, Verdict.t()} | {:error, any()}
  def run(agent_name, opts \\ [])
end
```

## Guard Conditions

1. **Isolation Guard**:
   - The `generate/3` function must verify that no elicitation conversation history is passed in its arguments or options.
2. **Fail-Safe Guard**:
   - If `InferenceBroker.complete/2` returns a timeout, error, or breach notification during evaluation, `run/2` must return `{:ok, %Verdict{status: :error, reasoning: "Evaluation aborted due to broker failure."}}` to prevent auto-deploy.
3. **Budget/Metering Guard**:
   - Both `generate/3` and `run/2` must require a valid metered run token. If no token is provided, or if the spend cap is breached, the execution fails safe.
