# Research: discord-notify

## Discord Incoming Webhook Payload
- **Decision**: The HTTPS POST payload will be `{"content": "message text"}`.
- **Rationale**: This is the required format by Discord for a simple incoming webhook.
- **Alternatives considered**: Rich embeds (discarded, outside scope).

## Test Transport Injection
- **Decision**: Use `Application.get_env(:agent_os, :discord_notify_transport, &Req.post/2)` to resolve the transport function.
- **Rationale**: It matches the Constitution's mandate (No Live Dependencies in Tests) and the pattern established by `web_search_mock_fn`. The test environment can inject a mock that asserts the payload and simulates success/failure responses.
- **Alternatives considered**: Mocking frameworks like Mox. Rejected for simplicity because a simple env-based function injection is trivial and matches existing patterns in `external_send`.

## Error Handling from Req
- **Decision**: The transport function should return `{:ok, %Req.Response{status: status}}` or `{:error, exception}`. `discord_notify` will pattern match: `status in 200..299` is `:ok`, otherwise `{:error, {:http_status, status, body}}`.
- **Rationale**: We must enforce loud failures (Invariant VI).
- **Alternatives considered**: `Req.post!` which raises on 4xx/5xx. Rejected because returning an explicit `{:error, reason}` is cleaner for connector bounds and `execute/2` contract.
