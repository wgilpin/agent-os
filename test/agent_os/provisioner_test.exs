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
    assert config.connectors == ["record_signal"]
    assert config.outputs == ["append_digest"]
    assert config.spend_cap == 5
  end

  test "check_drift/0 returns :ok when config matches manifest" do
    assert Provisioner.check_drift() == :ok
  end

  test "check_drift/0 returns {:drift, fields} when connectors drift" do
    config = Application.get_env(:agent_os, :agent)
    updated_config = Keyword.put(config, :connectors, ["some_other_connector"])
    Application.put_env(:agent_os, :agent, updated_config)

    assert {:drift, [:connectors]} = Provisioner.check_drift()
  end

  test "check_drift/0 returns {:drift, fields} when outputs drift" do
    config = Application.get_env(:agent_os, :agent)
    updated_config = Keyword.put(config, :outputs, ["some_other_output"])
    Application.put_env(:agent_os, :agent, updated_config)

    assert {:drift, [:outputs]} = Provisioner.check_drift()
  end

  test "check_drift/0 returns {:drift, fields} when spend_cap drifts" do
    config = Application.get_env(:agent_os, :agent)
    updated_config = Keyword.put(config, :spend_cap, 999)
    Application.put_env(:agent_os, :agent, updated_config)

    assert {:drift, [:spend_cap]} = Provisioner.check_drift()
  end

  test "check_drift/0 returns {:drift, fields} with multiple mismatched fields" do
    config = Application.get_env(:agent_os, :agent)

    updated_config =
      config
      |> Keyword.put(:connectors, ["drifted"])
      |> Keyword.put(:spend_cap, 100)

    Application.put_env(:agent_os, :agent, updated_config)

    assert {:drift, [:connectors, :spend_cap]} = Provisioner.check_drift()
  end
end
