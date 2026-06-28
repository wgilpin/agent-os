defmodule AgentOS.EffectorTest do
  # Not async: StateStore is a registered name shared across effector testing and must run serially.
  use ExUnit.Case, async: false

  alias AgentOS.Effector
  alias AgentOS.StateStore
  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "roster_effector_#{System.unique_integer([:positive])}.term")

    on_exit(fn -> File.rm(tmp) end)

    # Start Registry and StateStore
    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({StateStore, name: "roster_trust", path: tmp, initial: %{records: []}})

    :ok
  end

  test "act performs kv_append action via StateStore" do
    action = %ProposedAction{type: "kv_append", recipient: nil, method: "append", payload: %{"k" => "v"}}
    grant = %Grant{connector: "kv_append", recipients: nil, methods: ["append"]}

    assert :ok = Effector.act(%{action: action, grant: grant})
    assert StateStore.snapshot("roster_trust") == %{records: [%{"k" => "v"}]}
  end

  test "act performs external_send mock" do
    action = %ProposedAction{type: "external_send", recipient: "owner-inbox", method: "send", payload: %{"text" => "hello"}}
    grant = %Grant{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}

    assert :ok = Effector.act(%{action: action, grant: grant})
  end

  test "act returns {:error, {:unknown_action, type}} for unknown action type" do
    action = %ProposedAction{type: "unknown_connector", recipient: nil, method: nil, payload: %{}}
    grant = %Grant{connector: "unknown_connector", recipients: nil, methods: nil}

    assert {:error, {:unknown_action, "unknown_connector"}} = Effector.act(%{action: action, grant: grant})
  end

  test "act_all performs multiple actions in order" do
    action1 = %ProposedAction{type: "kv_append", recipient: nil, method: "append", payload: %{"first" => true}}
    grant1 = %Grant{connector: "kv_append", recipients: nil, methods: ["append"]}

    action2 = %ProposedAction{type: "kv_append", recipient: nil, method: "append", payload: %{"digest" => "second"}}
    grant2 = %Grant{connector: "kv_append", recipients: nil, methods: ["append"]}

    assert :ok = Effector.act_all([
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
