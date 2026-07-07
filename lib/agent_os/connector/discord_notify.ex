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
      cost: 1000,
      tool_declaration: %{
        "type" => "function",
        "function" => %{
          "name" => "discord_notify",
          "description" => "Notify the user on Discord.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "text" => %{
                "type" => "string",
                "description" => "The message text to send to Discord."
              }
            },
            "required" => ["text"]
          }
        }
      }
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
  def execute(%ProposedAction{method: "notify", payload: %{"text" => text}}, secret)
      when is_binary(secret) do
    transport_fn = Application.get_env(:agent_os, :discord_notify_transport, &Req.post/2)
    # Req.post/2 requires options as a keyword list; a map raises ArgumentError.
    payload = [json: %{content: text}]

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
  def execute_tool(%{"text" => text}, secret) when is_binary(secret) do
    # Reuse the internal payload construction; the rail expects {:ok, result} on
    # success (bare :ok would be recorded to the transcript as an error).
    case execute(
           %ProposedAction{type: "external_send", method: "notify", payload: %{"text" => text}},
           secret
         ) do
      :ok -> {:ok, %{"status" => "sent"}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl AgentOS.Connector
  def render(_grant) do
    "[EXTERNAL] NOTIFY THE USER ON DISCORD (methods: [\"notify\"])"
  end
end
