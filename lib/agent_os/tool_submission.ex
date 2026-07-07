defmodule AgentOS.ToolSubmission do
  @moduledoc """
  The typed parse of a `/v1/tool_calls` request body, validated before anything
  reaches the capability rail.

  A submission carries only a run token (resolved to a manifest by the substrate,
  never by the agent) and a list of OpenAI-shaped tool calls — the exact shape
  `AgentOS.CapabilityRail.evaluate_tool_calls/4` already consumes on the inference
  path. No credential, manifest, or capability data crosses this boundary.

  Validation is deliberately shallow: a malformed *request* (not JSON, missing
  `run_token`, or `tool_calls` not a list) is refused here with `:bad_request`; a
  malformed *call* (an element with no resolvable `function.name`) is NOT rejected
  here — it is passed to the rail, which records it `:rejected` with a reason code.
  Malformed requests are refused, malformed calls are recorded (FR-003 vs the
  edge case).
  """

  @enforce_keys [:run_token, :tool_calls]
  defstruct [:run_token, :tool_calls]

  @type t :: %__MODULE__{
          run_token: String.t(),
          tool_calls: [map()]
        }

  @doc """
  Parses a decoded request body map into a typed `%ToolSubmission{}`.

  Requires a binary `run_token` and a list `tool_calls` (an empty list is valid —
  it evaluates to an empty result set). Returns `{:error, :bad_request}` on any
  other shape.
  """
  @spec from_map(any()) :: {:ok, t()} | {:error, :bad_request}
  def from_map(%{} = map) do
    run_token = Map.get(map, "run_token") || Map.get(map, :run_token)
    tool_calls = Map.get(map, "tool_calls") || Map.get(map, :tool_calls)

    if is_binary(run_token) and run_token != "" and is_list(tool_calls) do
      {:ok, %__MODULE__{run_token: run_token, tool_calls: tool_calls}}
    else
      {:error, :bad_request}
    end
  end

  def from_map(_), do: {:error, :bad_request}
end
