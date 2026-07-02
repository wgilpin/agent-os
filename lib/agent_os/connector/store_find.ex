defmodule AgentOS.Connector.StoreFind do
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "store_find",
      mutating?: false,
      requires_deploy_consent?: false,
      requires_runtime_approval?: false,
      credential: nil,
      cost: 0,
      tool_declaration: %{
        "type" => "function",
        "function" => %{
          "name" => "store_find",
          "description" => "Query records in the state store using predicates.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "handle" => %{
                "type" => "string",
                "description" => "The logical handle (alias) of the target store."
              },
              "predicates" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "field" => %{"type" => "string"},
                    "operator" => %{
                      "type" => "string",
                      "enum" => ["=", "!=", "<", ">", "<=", ">="]
                    },
                    "value" => %{"type" => "string"}
                  },
                  "required" => ["field", "operator", "value"]
                },
                "description" => "List of predicate filters."
              },
              "limit" => %{"type" => "integer"},
              "order_by" => %{"type" => "string"},
              "order" => %{"type" => "string", "enum" => ["asc", "desc"]}
            },
            "required" => ["handle"]
          }
        }
      }
    }
  end

  @impl AgentOS.Connector
  def scope(_boundaries) do
    %Grant{
      connector: "store_find",
      recipients: nil,
      methods: ["find"]
    }
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{} = action, _secret) do
    namespace =
      action.grant_resolved_namespace ||
        raise "Substrate error: missing resolved namespace for store_find"

    AgentOS.StateStore.query(namespace, action.payload)
  end

  @impl AgentOS.Connector
  def execute_tool(arguments, _secret) do
    handle = Map.get(arguments, "handle") || Map.get(arguments, :handle)

    case resolve_namespace_from_manifest(handle) do
      nil ->
        {:error, {:unknown_handle, handle}}

      namespace ->
        AgentOS.StateStore.query(namespace, arguments)
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
    "QUERY RECORD STORE"
  end
end
