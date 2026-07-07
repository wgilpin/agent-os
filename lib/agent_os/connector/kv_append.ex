defmodule AgentOS.Connector.KvAppend do
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "kv_append",
      mutating?: true,
      requires_deploy_consent?: false,
      requires_runtime_approval?: false,
      credential: nil,
      cost: 0,
      tool_declaration: %{
        "type" => "function",
        "function" => %{
          "name" => "kv_append",
          "description" => "Append an item to a list in the KV store.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "key" => %{"type" => "string"},
              "value" => %{"type" => "string"}
            },
            "required" => ["key", "value"]
          }
        }
      }
    }
  end

  @impl AgentOS.Connector
  def scope(_boundaries) do
    %Grant{
      connector: "kv_append",
      recipients: nil,
      methods: ["append"]
    }
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{method: "append", payload: payload}, _secret) do
    {:ok, {:state_store, :append, "roster_trust", {:append, :records, payload}}}
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{method: other}, _secret) do
    {:error, {:unknown_method, other}}
  end

  @impl AgentOS.Connector
  def execute_tool(arguments, _secret) do
    # Tool-channel execution: the capability rail invokes this inline during inference.
    # kv_append is fixed to the roster_trust store (mirrors execute/2), so we perform the
    # append directly and return a synthetic success the rail records to the transcript.
    case Map.get(arguments, "value") do
      value when is_binary(value) ->
        case AgentOS.StateStore.apply_action(
               "roster_trust",
               {:append, :records, %{"digest" => value}}
             ) do
          :ok -> {:ok, %{"status" => "appended"}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :missing_value}
    end
  end

  @impl AgentOS.Connector
  def render(_grant) do
    "WRITE TO YOUR LOCAL STATE STORE (methods: [\"append\"])"
  end
end
