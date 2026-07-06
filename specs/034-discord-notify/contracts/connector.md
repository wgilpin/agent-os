# Contract: discord-notify Connector

The `discord_notify` connector implements the `AgentOS.Connector` behaviour.

## Capabilities

- **Metadata**:
  - `mutating?`: `true`
  - `requires_deploy_consent?`: `true`
  - `requires_runtime_approval?`: `false`
  - `credential`: `"DISCORD_WEBHOOK_URL"` (or configured ID)
  - `cost`: `0.001` (micro-dollar metering)

## Execute

`execute(action, grant)`

### Valid Actions
- `{"method" => "notify", "text" => "message text"}`

### Returns
- `{:ok, nil}` on successful delivery.
- `{:error, reason}` on delivery failure, malformed payload, or unknown method.
- Fails loudly if credential is not successfully injected by the `CredentialProxy`.

## Capability Render
- Presents as an `[EXTERNAL]` badge with a human-readable description such as "NOTIFY THE USER ON DISCORD".
