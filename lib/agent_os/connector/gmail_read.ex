defmodule AgentOS.Connector.GmailRead do
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "gmail_read",
      mutating?: false,
      requires_approval?: false,
      credential: nil,
      cost: 0
    }
  end

  @impl AgentOS.Connector
  def scope(_boundaries) do
    %Grant{
      connector: "gmail_read",
      recipients: nil,
      methods: nil
    }
  end

  @impl AgentOS.Connector
  def execute(_action, _secret) do
    {:error, :not_implemented}
  end

  @impl AgentOS.Connector
  def render(_grant) do
    "READ INCOMING EMAILS FROM GMAIL"
  end
end
