# Quickstart: discord-notify

To manually smoke test the `discord_notify` connector in an `iex` session:

1. Create a Discord channel and configure an incoming webhook.
2. In `.env` or system environment, configure the mapped credential:
   ```env
   DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
   ```
3. Start an interactive session:
   ```bash
   iex -S mix
   ```
4. Run the connector with a mocked grant providing the credential ID (assuming ID is "DISCORD_WEBHOOK_URL"):
   ```elixir
   grant = %AgentOS.Connector.Grant{
     methods: ["notify"],
     credential: "DISCORD_WEBHOOK_URL"
   }
   
   action = %{
     "method" => "notify",
     "text" => "Hello from Agent OS"
   }
   
   AgentOS.Connector.DiscordNotify.execute(action, grant)
   ```
