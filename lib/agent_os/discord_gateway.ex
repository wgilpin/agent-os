defmodule AgentOS.DiscordGateway do
  @moduledoc """
  A supervised websocket client for the Discord Gateway.
  Filters incoming messages and routes valid ones to AgentOS.TriggerGateway.
  """

  use WebSockex
  require Logger

  @gateway_url "wss://gateway.discord.gg/?v=10&encoding=json"

  def start_link(_opts \\ []) do
    credentials = Application.get_env(:agent_os, :credentials, %{})
    bot_token = Map.get(credentials, :discord_bot_token) || System.get_env("DISCORD_BOT_TOKEN")

    user_id =
      Application.get_env(:agent_os, :discord_allowed_user_id) ||
        System.get_env("DISCORD_ALLOWED_USER_ID")

    channel_id =
      Application.get_env(:agent_os, :discord_allowed_channel_id) ||
        System.get_env("DISCORD_ALLOWED_CHANNEL_ID")

    target_agent =
      Application.get_env(:agent_os, :discord_target_agent) ||
        System.get_env("DISCORD_TARGET_AGENT")

    if is_nil(bot_token) do
      Logger.warning("DiscordGateway skipping start: no bot token provided")
      :ignore
    else
      state = %{
        token: bot_token,
        user_id: user_id,
        channel_id: channel_id,
        target_agent: target_agent,
        seq: nil
      }

      WebSockex.start_link(@gateway_url, __MODULE__, state, name: __MODULE__)
    end
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    payload = Jason.decode!(msg)

    case payload do
      # Hello packet from Discord
      %{"op" => 10, "d" => %{"heartbeat_interval" => interval}} ->
        Logger.info("DiscordGateway received Hello. Starting heartbeats every #{interval}ms")
        # Send initial Identify
        identify = %{
          "op" => 2,
          "d" => %{
            "token" => state.token,
            # MESSAGE_CONTENT (32768) + GUILD_MESSAGES (512)
            "intents" => 33280,
            "properties" => %{
              "os" => "linux",
              "browser" => "agent_os",
              "device" => "agent_os"
            }
          }
        }

        {:reply, {:text, Jason.encode!(identify)}, state}

      # Standard dispatch events
      %{"op" => 0, "t" => "MESSAGE_CREATE", "d" => d, "s" => seq} ->
        state = %{state | seq: seq}
        handle_message(d, state)
        {:ok, state}

      # Ignore other dispatch events, but update seq
      %{"op" => 0, "s" => seq} ->
        {:ok, %{state | seq: seq}}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_disconnect(status_map, state) do
    attempt = Map.get(status_map, :attempt_number, 1)
    # Exponential backoff capped at 30 seconds
    backoff = min((1000 * :math.pow(2, attempt)) |> trunc(), 30_000)

    Logger.warning(
      "DiscordGateway disconnected (attempt #{attempt}). Reconnecting in #{backoff}ms"
    )

    Process.sleep(backoff)

    {:reconnect, state}
  end

  defp handle_message(d, state) do
    author_id = get_in(d, ["author", "id"])
    channel_id = Map.get(d, "channel_id")
    content = Map.get(d, "content")

    cond do
      author_id != state.user_id ->
        Logger.warning(
          "Unauthorized Discord message from user: #{author_id}. Expected: #{state.user_id}"
        )

      channel_id != state.channel_id ->
        Logger.warning(
          "Unauthorized Discord channel: #{channel_id}. Expected: #{state.channel_id}"
        )

      true ->
        Logger.debug("DiscordGateway routing message to #{state.target_agent}")
        AgentOS.TriggerGateway.submit({:message, state.target_agent, content})
    end
  end
end
