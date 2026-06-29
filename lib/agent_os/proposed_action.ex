defmodule AgentOS.ProposedAction do
  @moduledoc """
  Defines a proposed action emitted by the agent.
  """

  @enforce_keys [:type]
  defstruct [:type, :recipient, :method, :payload]

  @type t :: %__MODULE__{
          type: String.t(),
          recipient: String.t() | nil,
          method: String.t() | nil,
          payload: map()
        }

  @doc """
  Builds a ProposedAction struct from a map, validating shape.
  Returns `{:ok, %ProposedAction{}}` or `{:error, :bad_shape}`.
  """
  @spec from_map(any()) :: {:ok, t()} | {:error, :bad_shape}
  def from_map(map) when is_map(map) do
    case Map.get(map, "type") do
      type when is_binary(type) and type != "" ->
        {:ok,
         %__MODULE__{
           type: type,
           recipient: Map.get(map, "recipient"),
           method: Map.get(map, "method"),
           payload: Map.get(map, "payload", %{})
         }}

      _ ->
        {:error, :bad_shape}
    end
  end

  def from_map(_), do: {:error, :bad_shape}
end
