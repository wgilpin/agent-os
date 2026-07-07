# Quickstart: Discord Ingress

## Configuration
The following environment variables or configuration must be set:

- `DISCORD_BOT_TOKEN`: The static bot token used to authenticate with Discord.
- `DISCORD_ALLOWED_USER_ID`: The Discord User ID permitted to send messages.
- `DISCORD_ALLOWED_CHANNEL_ID`: The channel ID the bot will listen to.
- `DISCORD_TARGET_AGENT`: The name of the agent to which messages are routed (e.g. `priorities-coach`).

*(In practice, the token is provided via `CredentialSource`, while IDs can be configured in `config/config.exs` or application environment)*.

## Running
When the substrate boots, the supervised connection starts automatically.
Send a message in the configured Discord channel from the configured user, and it will be routed to the waiting agent's trigger.
