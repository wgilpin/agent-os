defmodule AgentOS.EffectorTest do
  # Not async: StateStore is a registered name shared across effector testing and must run serially.
  use ExUnit.Case, async: false

  alias AgentOS.Effector
  alias AgentOS.StateStore
  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant
  alias AgentOS.CredentialProxy
  import ExUnit.CaptureLog

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "roster_effector_#{System.unique_integer([:positive])}.term")

    on_exit(fn -> File.rm(tmp) end)

    # Start Registry, StateStore and CredentialProxy
    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({StateStore, name: "roster_trust", path: tmp, initial: %{records: []}})
    start_supervised!(CredentialProxy)

    # Configure external_send_sink_pid to receive the payload in tests
    Application.put_env(:agent_os, :external_send_sink_pid, self())
    on_exit(fn -> Application.delete_env(:agent_os, :external_send_sink_pid) end)

    :ok
  end

  test "act performs kv_append action via StateStore" do
    action = %ProposedAction{
      type: "kv_append",
      recipient: nil,
      method: "append",
      payload: %{"k" => "v"}
    }

    grant = %Grant{connector: "kv_append", recipients: nil, methods: ["append"]}

    assert :ok = Effector.act(%{action: action, grant: grant})
    assert StateStore.snapshot("roster_trust") == %{records: [%{"k" => "v"}]}
  end

  test "B1 & B2: act performs external_send mock injecting secret post-approval, secret not leaked" do
    action = %ProposedAction{
      type: "external_send",
      recipient: "owner-inbox",
      method: "send",
      payload: %{"text" => "hello"}
    }

    grant = %Grant{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}

    # Perform action and assert success
    log =
      capture_log(fn ->
        assert :ok = Effector.act(%{action: action, grant: grant})
      end)

    # B1: Assert mock sink records the delivered payload with the injected credential
    assert_receive {:external_send,
                    %{action: ^action, credential: "test_secret_outbound_token_value"}}

    # B2: Assert secret value is absent from logs and returned value (which is :ok)
    refute String.contains?(log, "test_secret_outbound_token_value")
  end

  test "B3: kv_append action completes without proxy interaction" do
    action = %ProposedAction{
      type: "kv_append",
      recipient: nil,
      method: "append",
      payload: %{"k" => "v"}
    }

    grant = %Grant{connector: "kv_append", recipients: nil, methods: ["append"]}

    assert :ok = Effector.act(%{action: action, grant: grant})
    assert StateStore.snapshot("roster_trust") == %{records: [%{"k" => "v"}]}

    # Assert no external send message was received
    refute_received {:external_send, _}
  end

  test "B4: effector fails closed when proxy doesn't have the required credential" do
    stop_supervised(CredentialProxy)
    Application.put_env(:agent_os, :credentials, %{})

    on_exit(fn ->
      Application.put_env(:agent_os, :credentials, %{
        outbound_token: "test_secret_outbound_token_value",
        model_key: "test_secret_model_key_value"
      })
    end)

    start_supervised!(CredentialProxy)

    action = %ProposedAction{
      type: "external_send",
      recipient: "owner-inbox",
      method: "send",
      payload: %{"text" => "hello"}
    }

    grant = %Grant{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}

    # Perform action and assert failure
    log =
      capture_log(fn ->
        assert {:error, {:unknown_credential, :outbound_token}} =
                 Effector.act(%{action: action, grant: grant})
      end)

    # Fail closed -> mock sink did not run
    refute_received {:external_send, _}
    # Log must be loud (fail-closed logged) but not contain the secret
    assert String.contains?(log, "unknown credential")
    refute String.contains?(log, "test_secret_outbound_token_value")
  end

  test "act returns {:error, {:unknown_action, type}} for unknown action type" do
    action = %ProposedAction{type: "unknown_connector", recipient: nil, method: nil, payload: %{}}
    grant = %Grant{connector: "unknown_connector", recipients: nil, methods: nil}

    assert {:error, {:unknown_action, "unknown_connector"}} =
             Effector.act(%{action: action, grant: grant})
  end

  test "act_all performs multiple actions in order" do
    action1 = %ProposedAction{
      type: "kv_append",
      recipient: nil,
      method: "append",
      payload: %{"first" => true}
    }

    grant1 = %Grant{connector: "kv_append", recipients: nil, methods: ["append"]}

    action2 = %ProposedAction{
      type: "kv_append",
      recipient: nil,
      method: "append",
      payload: %{"digest" => "second"}
    }

    grant2 = %Grant{connector: "kv_append", recipients: nil, methods: ["append"]}

    assert :ok =
             Effector.act_all([
               %{action: action1, grant: grant1},
               %{action: action2, grant: grant2}
             ])

    assert StateStore.snapshot("roster_trust") == %{
             records: [
               %{"first" => true},
               %{"digest" => "second"}
             ]
           }
  end

  test "structural ring split: output_check must not mutate state" do
    content = File.read!("lib/agent_os/output_check.ex")
    refute content =~ "apply_action"
    refute content =~ "StateStore"
    refute content =~ "RosterStore"
  end
end
