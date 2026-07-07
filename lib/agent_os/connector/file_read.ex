defmodule AgentOS.Connector.FileRead do
  @moduledoc """
  A connector that securely reads from a file bound via a manifest grant.
  """
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "file_read",
      mutating?: false,
      requires_deploy_consent?: false,
      requires_runtime_approval?: false,
      credential: nil,
      cost: 0,
      tool_declaration: %{
        "type" => "function",
        "function" => %{
          "name" => "file_read",
          "description" => "Read a bound file from the file system.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{},
            "required" => []
          }
        }
      }
    }
  end

  @impl AgentOS.Connector
  def scope(boundaries) do
    path =
      case Map.get(boundaries, :target_locations, []) do
        [first | _] -> first
        _ -> nil
      end

    %Grant{
      connector: "file_read",
      recipients: nil,
      methods: nil,
      handle: "priorities_doc",
      namespace: nil,
      path: path
    }
  end

  @impl AgentOS.Connector
  def render(%Grant{path: path}) do
    "[EXTERNAL] READ DOCUMENT AT #{path}"
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{grant_resolved_path: path}, _secret) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%ProposedAction{grant_resolved_path: nil}, _secret) do
    {:error, :missing_path}
  end
end
