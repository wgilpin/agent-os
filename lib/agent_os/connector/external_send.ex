defmodule AgentOS.Connector.ExternalSend do
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "external_send",
      mutating?: true,
      requires_deploy_consent?: true,
      requires_runtime_approval?: true,
      credential: :outbound_token,
      cost: 2000
    }
  end

  @impl AgentOS.Connector
  def scope(boundaries) do
    egress_domains = Map.get(boundaries, :egress_domains) || Map.get(boundaries, "egress_domains")

    recipients =
      if egress_domains && egress_domains != [] do
        Enum.sort(egress_domains)
      else
        nil
      end

    %Grant{
      connector: "external_send",
      recipients: recipients,
      methods: ["send"]
    }
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{method: "send"} = action, secret) when is_binary(secret) do
    AgentOS.Connector.external_send_sink(action, secret)
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{method: other}, _secret) do
    {:error, {:unknown_method, other}}
  end

  @impl AgentOS.Connector
  def render(%Grant{recipients: recs}) do
    badge = "[EXTERNAL] "
    phrase = "SEND MESSAGES OUT TO EXTERNAL RECIPIENTS"

    scope_str =
      if recs do
        " (recipients: #{inspect(recs)}, methods: [\"send\"])"
      else
        " (methods: [\"send\"])"
      end

    badge <> phrase <> scope_str
  end
end
