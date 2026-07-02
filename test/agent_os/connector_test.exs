defmodule AgentOS.Connector.TestFixture do
  @behaviour AgentOS.Connector

  def metadata do
    %{
      name: "test_fixture",
      mutating?: true,
      requires_deploy_consent?: true,
      requires_runtime_approval?: true,
      credential: :test_token,
      cost: 500
    }
  end

  def scope(_boundaries) do
    %AgentOS.Manifest.Grant{connector: "test_fixture"}
  end

  def execute(action, secret) do
    parent_pid = Map.get(action.payload, "parent_pid")
    if parent_pid, do: send(parent_pid, {:test_fixture_executed, secret})
    :ok
  end

  def render(_grant) do
    "TEST FIXTURE CAPABILITY"
  end
end

defmodule AgentOS.Connector.TimeoutFixture do
  @behaviour AgentOS.Connector

  def metadata do
    %{
      name: "timeout_fixture",
      mutating?: true,
      requires_deploy_consent?: false,
      requires_runtime_approval?: false,
      credential: nil,
      cost: 0
    }
  end

  def scope(_boundaries) do
    %AgentOS.Manifest.Grant{connector: "timeout_fixture"}
  end

  def execute(_action, _secret) do
    Process.sleep(10000)
    :ok
  end

  def render(_grant) do
    "TIMEOUT FIXTURE"
  end
end

defmodule AgentOS.Connector.CrashFixture do
  @behaviour AgentOS.Connector

  def metadata do
    %{
      name: "crash_fixture",
      mutating?: true,
      requires_deploy_consent?: false,
      requires_runtime_approval?: false,
      credential: nil,
      cost: 0
    }
  end

  def scope(_boundaries) do
    %AgentOS.Manifest.Grant{connector: "crash_fixture"}
  end

  def execute(_action, _secret) do
    raise RuntimeError, "intentional crash"
  end

  def render(_grant) do
    "CRASH FIXTURE"
  end
end

defmodule AgentOS.ConnectorTest do
  use ExUnit.Case, async: false

  alias AgentOS.Connector
  alias AgentOS.ProposedAction
  alias AgentOS.Effector
  alias AgentOS.CredentialProxy
  alias AgentOS.Manifest.Grant

  setup do
    AgentOS.TestHelper.start_mounts!()

    orig_registry = Application.get_env(:agent_os, :connector_registry)
    orig_credentials = Application.get_env(:agent_os, :credentials)

    # Seed the Application config environment with credentials for testing
    Application.put_env(
      :agent_os,
      :credentials,
      Map.put(orig_credentials || %{}, :test_token, "test_secret_fixture_value")
    )

    if Process.whereis(AgentOS.ConnectorSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: AgentOS.ConnectorSupervisor})
    end

    if Process.whereis(CredentialProxy) == nil do
      start_supervised!(CredentialProxy)
    end

    on_exit(fn ->
      # Restore config overrides
      if orig_registry,
        do: Application.put_env(:agent_os, :connector_registry, orig_registry),
        else: Application.delete_env(:agent_os, :connector_registry)

      if orig_credentials,
        do: Application.put_env(:agent_os, :credentials, orig_credentials),
        else: Application.delete_env(:agent_os, :credentials)
    end)

    :ok
  end

  test "auto-discovers migrated and test-only connector modules" do
    # Clean registry settings to let auto-discovery run
    Application.delete_env(:agent_os, :connector_registry)

    registry = Connector.registry()

    assert Map.has_key?(registry, "kv_append")
    assert Map.has_key?(registry, "external_send")
    assert Map.has_key?(registry, "gmail_read")
    assert Map.has_key?(registry, "gmail_draft")
    assert Map.has_key?(registry, "test_fixture")

    assert {:ok, AgentOS.Connector.TestFixture} = Connector.get_module("test_fixture")
  end

  test "resolves and injects credentials dynamically post-approval" do
    action = %ProposedAction{
      type: "test_fixture",
      method: "send",
      payload: %{"parent_pid" => self(), "text" => "hello"}
    }

    grant = %Grant{connector: "test_fixture"}

    # Execute the action via Effector.act/1
    assert :ok = Effector.act(%{action: action, grant: grant})

    # Assert that the dynamically resolved credential was injected and received by executor
    assert_receive {:test_fixture_executed, "test_secret_fixture_value"}
  end

  test "isolated execution fails closed on timeout" do
    action = %ProposedAction{
      type: "timeout_fixture",
      method: "run",
      payload: %{}
    }

    grant = %Grant{connector: "timeout_fixture"}

    # Effector execution runs timeboxed and should return a timeout error within 5 seconds
    assert {:error, :timeout} = Effector.act(%{action: action, grant: grant})
  end

  test "isolated execution fails closed on crash without killing substrate" do
    action = %ProposedAction{
      type: "crash_fixture",
      method: "run",
      payload: %{}
    }

    grant = %Grant{connector: "crash_fixture"}

    # Effector execution catches exceptions and returns error tuple
    assert {:error, {:raised, %RuntimeError{message: "intentional crash"}}} =
             Effector.act(%{action: action, grant: grant})
  end
end
