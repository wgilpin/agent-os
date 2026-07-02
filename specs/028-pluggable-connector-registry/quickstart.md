# Quickstart: Implementing a Pluggable Connector

This guide demonstrates how to add a new capability to AgentOS by creating a single self-contained connector module.

## Step 1: Create the Connector Module
Create a new file under `lib/agent_os/connector/slack_send.ex`:

```elixir
defmodule AgentOS.Connector.SlackSend do
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "slack_send",
      mutating?: true,
      requires_approval?: true,
      credential: :slack_token,
      cost: 500
    }
  end

  @impl AgentOS.Connector
  def scope(boundaries) do
    # Map domain boundaries to grant (supporting both atom and string keys)
    egress_domains = Map.get(boundaries, :egress_domains) || Map.get(boundaries, "egress_domains")

    recipients =
      if egress_domains && egress_domains != [] do
        Enum.sort(egress_domains)
      else
        nil
      end
 
    %Grant{
      connector: "slack_send",
      recipients: recipients,
      methods: ["send_message"]
    }
  end
 
  @impl AgentOS.Connector
  def execute(%ProposedAction{method: "send_message", payload: %{"text" => text}}, secret) do
    # Injected token (from SLACK_TOKEN env var) is available in `secret`
    # Execute the API call safely here
    :ok
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{method: other}, _secret) do
    {:error, {:unknown_method, other}}
  end

  @impl AgentOS.Connector
  def render(%Grant{recipients: recs}) do
    # Deterministic consent phrase
    "[EXTERNAL] SEND MESSAGES TO SLACK WORKSPACE (recipients: #{inspect(recs)})"
  end
end
```

## Step 2: Configure Credentials
Declare the `SLACK_TOKEN` environment variable in your `.env` or system environment:
```bash
export SLACK_TOKEN="xoxb-test-token"
```

## Step 3: Run the Application
Restart the AgentOS node. The dynamic module scanner automatically registers `slack_send` during boot time without editing any other file.
