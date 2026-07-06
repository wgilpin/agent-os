defmodule AgentOS.Connector.DiscordNotifyTest do
  use ExUnit.Case, async: true

  alias AgentOS.Connector.DiscordNotify
  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  setup do
    Application.delete_env(:agent_os, :discord_notify_transport)
    :ok
  end

  test "metadata returns correct capability" do
    meta = DiscordNotify.metadata()
    assert meta.name == "discord_notify"
    assert meta.mutating? == true
    assert meta.requires_deploy_consent? == true
    assert meta.requires_runtime_approval? == false
    assert meta.credential == :discord_webhook_url
    assert meta.cost > 0
  end

  test "execute/2 successful HTTPS POST payload formatting" do
    test_pid = self()

    Application.put_env(:agent_os, :discord_notify_transport, fn url, body ->
      send(test_pid, {:post_called, url, body})
      {:ok, %Req.Response{status: 204}}
    end)

    action = %ProposedAction{type: "external_send", method: "notify", payload: %{"text" => "Hello world"}}
    secret = "https://hooks.discord.com/fake"

    assert :ok = DiscordNotify.execute(action, secret)

    assert_receive {:post_called, url, payload}
    assert url == secret
    assert payload == %{json: %{content: "Hello world"}}
  end

  test "execute/2 returns unknown_method for invalid actions" do
    action = %ProposedAction{type: "external_send", method: "unknown", payload: %{}}
    assert {:error, {:unknown_method, "unknown"}} = DiscordNotify.execute(action, "secret")
  end

  test "execute/2 loud failure on 4xx/5xx responses" do
    Application.put_env(:agent_os, :discord_notify_transport, fn _url, _body ->
      {:ok, %Req.Response{status: 400, body: "Bad Request"}}
    end)

    action = %ProposedAction{type: "external_send", method: "notify", payload: %{"text" => "Hello"}}
    assert {:error, {:http_status, 400, "Bad Request"}} = DiscordNotify.execute(action, "secret")
  end

  test "execute/2 loud failure on network timeout/error" do
    Application.put_env(:agent_os, :discord_notify_transport, fn _url, _body ->
      {:error, :timeout}
    end)

    action = %ProposedAction{type: "external_send", method: "notify", payload: %{"text" => "Hello"}}
    assert {:error, :timeout} = DiscordNotify.execute(action, "secret")
  end
end
