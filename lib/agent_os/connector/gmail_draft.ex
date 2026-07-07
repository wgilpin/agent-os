defmodule AgentOS.Connector.GmailDraft do
  @behaviour AgentOS.Connector


  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "gmail_draft",
      mutating?: true,
      requires_deploy_consent?: false,
      requires_runtime_approval?: false,
      credential: :gmail_oauth_token,
      cost: 1500,
      tool_declaration: %{
        "type" => "function",
        "function" => %{
          "name" => "gmail_draft",
          "description" => "Draft an email using Gmail.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "to" => %{"type" => "string"},
              "subject" => %{"type" => "string"},
              "body" => %{"type" => "string"}
            },
            "required" => ["to", "subject", "body"]
          }
        }
      }
    }
  end

  @impl AgentOS.Connector
  def scope(_boundaries) do
    %Grant{
      connector: "gmail_draft",
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
    "CREATE DRAFT EMAILS IN GMAIL"
  end
end
