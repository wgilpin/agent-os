defmodule AgentOS.Connector.GmailRead do
  @behaviour AgentOS.Connector

  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "gmail_read",
      mutating?: false,
      requires_deploy_consent?: false,
      requires_runtime_approval?: false,
      credential: :gmail_oauth_token,
      cost: 500,
      tool_declaration: %{
        "type" => "function",
        "function" => %{
          "name" => "gmail_read",
          "description" => "Read emails from Gmail.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{
                "type" => "string",
                "description" => "The search query."
              }
            },
            "required" => ["query"]
          }
        }
      }
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
