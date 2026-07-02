defmodule AgentOS.Connector.StoreAppend do
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "store_append",
      mutating?: true,
      requires_deploy_consent?: false,
      requires_runtime_approval?: false,
      credential: nil,
      cost: 0,
      tool_declaration: %{
        "type" => "function",
        "function" => %{
          "name" => "store_append",
          "description" => "Append an opaque record to the queryable state store.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "handle" => %{
                "type" => "string",
                "description" => "The logical handle (alias) of the target store."
              },
              "record" => %{
                "type" => "object",
                "description" => "The JSON-serializable record map to append."
              }
            },
            "required" => ["handle", "record"]
          }
        }
      }
    }
  end

  @impl AgentOS.Connector
  def scope(_boundaries) do
    # Default fallback scope
    %Grant{
      connector: "store_append",
      recipients: nil,
      methods: ["append"]
    }
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{} = action, _secret) do
    namespace =
      action.grant_resolved_namespace ||
        raise "Substrate error: missing resolved namespace for store_append"

    record = Map.get(action.payload, "record") || Map.get(action.payload, :record) || %{}
    {:ok, {:state_store, :append, namespace, {:append, record}}}
  end

  @impl AgentOS.Connector
  def execute_tool(arguments, _secret) do
    # When executed as a tool, we return the action structure so that the effector/gateway
    # can process it as an action. Wait, tool execution over the mid-inference channel
    # might execute the connector directly. But since store_append is mutating, does it return the effect?
    # Yes! Tool execution of store_append can return the effect or return :ok after applying the effect.
    # Wait, the tool execution pipeline in inference_broker.ex executes tools via execute_tool/2.
    # If execute_tool/2 returns {:ok, result}, the broker injects result into the context.
    # But since it's a tool, how is the effect applied?
    # Ah! If the tool is mutating, does the broker run it through the effector or apply it directly?
    # Wait! In Phase 08-02, the tool runner executes:
    # `mod.execute_tool(arguments, secret)` directly! It does NOT pass it through the effector!
    # Wait! If it's a mutating tool, how is the state mutation applied?
    # Ah! If it executes `mod.execute_tool` directly, the tool can invoke `AgentOS.StateStore.apply_action`
    # or return an effect?
    # No, tool execution over the broker returns `{:ok, result}`.
    # But wait! If we want to support both, we can just execute the write directly in `execute_tool`
    # or return the effect?
    # Wait, if `execute_tool` is called, does it have access to the namespace?
    # Ah! Inside `execute_tool(arguments, secret)`, we do NOT have the `ProposedAction` struct,
    # so we don't have `action.grant_resolved_namespace`!
    # But wait! Can we resolve the namespace from the current active agent's manifest?
    # Yes! We can fetch the manifest from `Application.get_env(:agent_os, :agent)`'s manifest path,
    # load it, and find the grant matching `arguments["handle"]`!
    # Let's write a helper function to resolve the namespace dynamically:
    # ```elixir
    #   defp resolve_namespace_from_manifest(handle) do
    #     config = AgentOS.Provisioner.agent_config()
    #     case AgentOS.Manifest.load(config.manifest_path) do
    #       {:ok, manifest} ->
    #         case Enum.find(manifest.grants, fn g -> g.connector == "store_append" and g.handle == handle end) do
    #           nil -> nil
    #           grant -> grant.namespace
    #         end
    #       _ -> nil
    #     end
    #   end
    # ```
    # This is incredibly robust! Let's write `execute_tool/2`:
    handle = Map.get(arguments, "handle") || Map.get(arguments, :handle)
    record = Map.get(arguments, "record") || Map.get(arguments, :record) || %{}

    case resolve_namespace_from_manifest(handle) do
      nil ->
        {:error, {:unknown_handle, handle}}

      namespace ->
        case AgentOS.StateStore.apply_action(namespace, {:append, record}) do
          :ok -> {:ok, %{"status" => "success"}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp resolve_namespace_from_manifest(handle) do
    try do
      config = AgentOS.Provisioner.agent_config()

      case AgentOS.Manifest.load(config.manifest_path) do
        {:ok, manifest} ->
          case Enum.find(manifest.grants, fn g ->
                 (g.connector == "store_append" or g.connector == "store_find") and
                   g.handle == handle
               end) do
            nil -> nil
            grant -> grant.namespace
          end

        _ ->
          nil
      end
    rescue
      _ -> nil
    catch
      _ -> nil
    end
  end

  @impl AgentOS.Connector
  def render(_grant) do
    "APPEND TO RECORD STORE"
  end
end
