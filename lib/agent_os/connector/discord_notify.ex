defmodule AgentOS.Connector.DiscordNotify do
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "discord_notify",
      mutating?: true,
      requires_deploy_consent?: true,
      requires_runtime_approval?: false,
      credential: :discord_webhook_url,
      cost: 1000
    }
  end

  @impl AgentOS.Connector
  def scope(_boundaries) do
    %Grant{
      connector: "discord_notify",
      recipients: nil,
      methods: ["notify"]
    }
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{method: "notify", payload: %{"text" => text}}, secret) when is_binary(secret) do
    transport_fn = Application.get_env(:agent_os, :discord_notify_transport, &Req.post/2)
    payload = %{json: %{content: text}}

    case transport_fn.(secret, payload) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{method: other}, _secret) do
    {:error, {:unknown_method, other}}
  end

  @impl AgentOS.Connector
  def render(_grant) do
    "[EXTERNAL] NOTIFY THE USER ON DISCORD (methods: [\"notify\"])"
  end
end
