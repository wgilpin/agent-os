defmodule AgentOS.EffectorTest do
  # Not async: StateStore is a registered name shared across effector testing and must run serially.
  use ExUnit.Case, async: false

  alias AgentOS.Effector
  alias AgentOS.StateStore

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "roster_effector_#{System.unique_integer([:positive])}.term")

    on_exit(fn -> File.rm(tmp) end)

    # Start Registry and StateStore
    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({StateStore, name: "roster_trust", path: tmp, initial: %{records: []}})

    :ok
  end

  test "act performs record_signal action via StateStore" do
    action = %{"type" => "record_signal", "payload" => %{"k" => "v"}}
    assert :ok = Effector.act(action)
    assert StateStore.snapshot("roster_trust") == %{records: [%{"k" => "v"}]}
  end

  test "act performs append_digest action via StateStore at v0" do
    action = %{"type" => "append_digest", "payload" => %{"text" => "hi"}}
    assert :ok = Effector.act(action)
    assert StateStore.snapshot("roster_trust") == %{records: [%{"digest" => "hi"}]}
  end

  test "act returns {:error, {:unknown_action, type}} for unknown action type" do
    action = %{"type" => "unknown_action", "payload" => %{"foo" => "bar"}}
    assert {:error, {:unknown_action, "unknown_action"}} = Effector.act(action)
    # Ensure no mutation happened
    assert StateStore.snapshot("roster_trust") == %{records: []}
  end

  test "act_all performs multiple actions in order" do
    a1 = %{"type" => "record_signal", "payload" => %{"first" => true}}
    a2 = %{"type" => "append_digest", "payload" => %{"text" => "second"}}

    assert :ok = Effector.act_all([a1, a2])

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
