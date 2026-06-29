defmodule AgentOS.Connector do
  @moduledoc """
  Defines the connector capability registry.
  """

  @type capability :: %{
          name: String.t(),
          mutating?: boolean(),
          requires_approval?: boolean(),
          credential: atom() | nil,
          cost: number()
        }

  @registry %{
    "kv_append" => %{
      name: "kv_append",
      mutating?: true,
      requires_approval?: false,
      credential: nil,
      cost: 1
    },
    "external_send" => %{
      name: "external_send",
      mutating?: true,
      requires_approval?: true,
      credential: :outbound_token,
      cost: 2
    }
  }

  @doc """
  Returns the complete connector registry map.
  """
  @spec registry() :: %{String.t() => capability()}
  def registry, do: @registry

  @doc """
  Looks up a connector by name in the registry.
  Returns `{:ok, capability}` or `{:error, :unknown_connector}`.
  """
  @spec get(String.t()) :: {:ok, capability()} | {:error, :unknown_connector}
  def get(name) when is_binary(name) do
    case Map.fetch(@registry, name) do
      {:ok, cap} -> {:ok, cap}
      :error -> {:error, :unknown_connector}
    end
  end

  @doc """
  Returns the list of all registered connector names.
  """
  @spec registered_names() :: [String.t()]
  def registered_names do
    Map.keys(@registry)
  end

  @doc """
  Executes the mock sink for external_send.
  Sends the action and injected credential to the test-registered process if configured.
  """
  @spec external_send_sink(any(), String.t()) :: :ok
  def external_send_sink(action, secret) when is_binary(secret) do
    case Application.get_env(:agent_os, :external_send_sink_pid) do
      pid when is_pid(pid) ->
        send(pid, {:external_send, %{action: action, credential: secret}})
        :ok

      _ ->
        :ok
    end
  end
end
