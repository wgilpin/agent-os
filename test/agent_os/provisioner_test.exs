defmodule AgentOS.ProvisionerTest do
  use ExUnit.Case, async: false

  alias AgentOS.Provisioner

  setup do
    original_config = Application.get_env(:agent_os, :agent)

    on_exit(fn ->
      if original_config do
        Application.put_env(:agent_os, :agent, original_config)
      else
        Application.delete_env(:agent_os, :agent)
      end
    end)

    :ok
  end

  test "agent_config/0 returns a map with all hard-wired keys" do
    config = Provisioner.agent_config()
    assert is_map(config)
    assert config.manifest_path == "manifests/discovery.md"
    assert config.agent_cmd == "docker"
    assert config.agent_args == []
    assert config.tz == "Etc/UTC"
    assert config.run_hour == 7

    assert config.grants == [
             %{connector: "kv_append", recipients: nil, methods: ["append"]},
             %{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}
           ]

    assert config.spend == %{cap: 500_000, window: :daily, on_breach: :kill}
  end

  test "check_drift/0 returns :ok when config matches manifest" do
    assert Provisioner.check_drift() == :ok
  end

  test "check_drift/0 returns {:drift, fields} when grants drift" do
    config = Application.get_env(:agent_os, :agent)

    updated_config =
      Keyword.put(config, :grants, [%{connector: "kv_append", recipients: nil, methods: []}])

    Application.put_env(:agent_os, :agent, updated_config)

    assert {:drift, [:grants]} = Provisioner.check_drift()
  end

  test "check_drift/0 returns {:drift, fields} when spend drifts" do
    config = Application.get_env(:agent_os, :agent)
    updated_config = Keyword.put(config, :spend, %{cap: 999, window: :daily, on_breach: :kill})
    Application.put_env(:agent_os, :agent, updated_config)

    assert {:drift, [:spend]} = Provisioner.check_drift()
  end

  test "check_drift/0 returns {:drift, fields} with multiple mismatched fields" do
    config = Application.get_env(:agent_os, :agent)

    updated_config =
      config
      |> Keyword.put(:grants, [])
      |> Keyword.put(:spend, %{cap: 100, window: :daily, on_breach: :kill})

    Application.put_env(:agent_os, :agent, updated_config)

    assert {:drift, [:grants, :spend]} = Provisioner.check_drift()
  end
end
