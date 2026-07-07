defmodule AgentOS.OutcomeRecord do
  @moduledoc """
  The terminal outcome record an agent prints to stdout on completion.

  Under the deterministic capability-rails architecture, an agent body acts only
  through the broker tool-call channel during inference (the rail gates, executes,
  parks, and records every effect to the `AgentOS.ActionTranscript`). All the body
  then prints is a single line of JSON describing *how the run ended* — an `outcome`
  and a `reason` — for run-log legibility. It is disposition, never an action list.

  This replaces the retired `{"actions":[…]}` stdout protocol.
  """

  @derive Jason.Encoder
  @type t :: %__MODULE__{
          outcome: String.t(),
          reason: String.t()
        }

  @enforce_keys [:outcome, :reason]
  defstruct [:outcome, :reason]

  @doc """
  Parses one line of agent stdout into an `%OutcomeRecord{}`.

  Requires a JSON object carrying both a string `"outcome"` and a string `"reason"`.
  Anything else — the legacy `{"actions":[…]}` shape, a missing key, a non-string
  value, non-JSON, or empty input — is `{:error, :malformed}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :malformed}
  def parse(stdout) when is_binary(stdout) do
    with trimmed <- String.trim(stdout),
         false <- trimmed == "",
         {:ok, decoded} <- Jason.decode(trimmed),
         %{"outcome" => outcome, "reason" => reason} <- decoded,
         true <- is_binary(outcome) and is_binary(reason) do
      {:ok, %__MODULE__{outcome: outcome, reason: reason}}
    else
      _ -> {:error, :malformed}
    end
  end

  def parse(_), do: {:error, :malformed}
end
