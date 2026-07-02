defmodule AgentOS.Connector.KvAppend do
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "kv_append",
      mutating?: true,
      requires_approval?: false,
      credential: nil,
      cost: 0
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
    AgentOS.StateStore.apply_action("roster_trust", {:append, :records, payload})
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{method: other}, _secret) do
    {:error, {:unknown_method, other}}
  end

  @impl AgentOS.Connector
  def render(_grant) do
    "WRITE TO YOUR LOCAL STATE STORE (methods: [\"append\"])"
  end
end
