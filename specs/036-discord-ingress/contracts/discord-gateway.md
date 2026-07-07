# Discord Gateway Interface

While this is an internal ingress feature, it depends on the external Discord Gateway v10 websocket API.

## Inbound Payload
```json
{
  "t": "MESSAGE_CREATE",
  "d": {
    "author": {
      "id": "1234567890"
    },
    "channel_id": "0987654321",
    "content": "Hello agent!"
  }
}
```

## Outbound Trigger
```elixir
AgentOS.TriggerGateway.submit({:message, target_agent, "Hello agent!"})
```
