# Phase 0: Research & Decisions

## 1. Websocket Client for Discord Gateway
**Decision**: Use `websockex` to manage the Discord Gateway connection.
**Rationale**: `websockex` is the standard, simple, pure-Elixir websocket client that integrates perfectly into OTP supervision trees (it behaves like a GenServer). This complies with the need for a "supervised substrate component that maintains the Discord Gateway connection" that can restart with backoff on failure.
**Alternatives considered**: 
- *Mint/Req*: While `Req` is present for HTTP, its websocket story is less suited for long-lived supervised gateway daemons compared to `websockex`.
- *Gun*: A robust Erlang HTTP/WS client, but heavier and less idiomatic Elixir compared to `websockex`.

## 2. Discord Gateway Payload Handling
**Decision**: Implement a `WebSockex` module (`AgentOS.DiscordGateway`) that connects to `wss://gateway.discord.gg/?v=10&encoding=json`.
**Rationale**: 
- It will send the standard Identify payload with the bot token.
- It will handle Heartbeat ACKs (and dispatch its own heartbeats).
- It will match on `MESSAGE_CREATE` dispatches.
- It will extract `author.id`, `channel_id`, and `content`.
- It will filter against the allowed `user_id` and `channel_id` provided during startup.

## 3. Substrate Trigger Integration
**Decision**: The ingress will directly call `AgentOS.TriggerGateway.submit({:message, target_agent, content})` on valid messages.
**Rationale**: Reusing the existing `TriggerGateway` intake ensures we do not build separate run-resume or reply-correlation logic, adhering to the spec. `target_agent` (the Priorities Coach agent name) will be configured alongside the connection.

## 4. Credential and Configuration Resolution
**Decision**: `AgentOS.DiscordGateway` will fetch the Discord bot token via `AgentOS.CredentialSource` during its `start_link` or `init` phase. 
**Rationale**: The spec mandates "The bot token is a static credential resolved substrate-side; nothing agent-observable contains it (invariant X)." Other configs (user ID, channel ID, target agent) can be passed via application env or start arguments.
