defmodule AgentOS.Connector.FileWrite do
  @moduledoc """
  A connector that securely and atomically writes to a file bound via a manifest grant.
  """
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "file_write",
      mutating?: true,
      requires_deploy_consent?: true,
      requires_runtime_approval?: false,
      credential: nil,
      cost: 0
    }
  end

  @impl AgentOS.Connector
  def render(%Grant{path: path}) do
    "[EXTERNAL] WRITE DOCUMENT AT #{path}"
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{grant_resolved_path: path, payload: payload}, _secret)
      when is_binary(path) do
    case Map.fetch(payload, "content") do
      {:ok, content} when is_binary(content) ->
        tmp_path = path <> ".tmp.#{System.unique_integer([:positive])}"

        with :ok <- File.write(tmp_path, content),
             :ok <- File.rename(tmp_path, path) do
          :ok
        else
          {:error, reason} ->
            File.rm(tmp_path)
            {:error, reason}
        end

      _ ->
        {:error, :missing_content}
    end
  end

  def execute(%ProposedAction{grant_resolved_path: nil}, _secret) do
    {:error, :missing_path}
  end
end
