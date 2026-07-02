defmodule AgentOS.StateStoreTest do
  # Not async: stores share registered name keys in tests and must run serially.
  use ExUnit.Case, async: false

  alias AgentOS.StateStore

  setup do
    # Unique temp paths per test
    tmp1 = Path.join(System.tmp_dir!(), "state_1_#{System.unique_integer([:positive])}.db")
    tmp2 = Path.join(System.tmp_dir!(), "state_2_#{System.unique_integer([:positive])}.db")

    on_exit(fn ->
      File.rm(tmp1)
      File.rm(tmp2)
    end)

    # Start the StateStore Registry required for string-based dynamic naming.
    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})

    {:ok, tmp1: tmp1, tmp2: tmp2}
  end

  test "snapshot returns the initial state map", %{tmp1: tmp} do
    start_supervised!({StateStore, name: "test_store_1", path: tmp, initial: %{records: []}})
    assert StateStore.snapshot("test_store_1") == %{records: []}
  end

  test "apply_action with append records an entry visible in subsequent snapshots", %{tmp1: tmp} do
    start_supervised!({StateStore, name: "test_store_1", path: tmp, initial: %{records: []}})
    assert :ok = StateStore.apply_action("test_store_1", {:append, :records, %{"k" => "v"}})
    assert %{records: [%{"k" => "v"}]} = StateStore.snapshot("test_store_1")
  end

  test "apply_action with put adds or overrides keys", %{tmp1: tmp} do
    start_supervised!({StateStore, name: "test_store_1", path: tmp, initial: %{}})
    assert :ok = StateStore.apply_action("test_store_1", {:put, :foo, "bar"})
    assert %{foo: "bar"} = StateStore.snapshot("test_store_1")
  end

  test "mutating a returned snapshot locally does not affect the store", %{tmp1: tmp} do
    start_supervised!({StateStore, name: "test_store_1", path: tmp, initial: %{records: []}})
    :ok = StateStore.apply_action("test_store_1", {:append, :records, %{"k" => "v"}})

    snap = StateStore.snapshot("test_store_1")
    _tampered = Map.put(snap, :records, [])

    assert %{records: [%{"k" => "v"}]} = StateStore.snapshot("test_store_1")
  end

  test "malformed actions are rejected without mutating state", %{tmp1: tmp} do
    start_supervised!({StateStore, name: "test_store_1", path: tmp, initial: %{records: []}})

    assert {:error, :bad_action} =
             StateStore.apply_action("test_store_1", {:not_append, :records, %{}})

    assert {:error, :bad_action} = StateStore.apply_action("test_store_1", :garbage)
    assert %{records: []} = StateStore.snapshot("test_store_1")
  end

  test "state survives a restart pointed at the same term-file", %{tmp1: tmp} do
    start_supervised!({StateStore, name: "test_store_1", path: tmp, initial: %{records: []}})
    :ok = StateStore.apply_action("test_store_1", {:append, :records, %{"persisted" => true}})

    # Restart the GenServer against the same path; it must reload persisted state.
    stop_supervised!("test_store_1")
    start_supervised!({StateStore, name: "test_store_1", path: tmp, initial: %{records: []}})

    assert %{records: [%{"persisted" => true}]} = StateStore.snapshot("test_store_1")
  end

  test "multiple isolated stores can be started and managed concurrently", %{
    tmp1: tmp1,
    tmp2: tmp2
  } do
    start_supervised!({StateStore, name: "store_a", path: tmp1, initial: %{records: []}})
    start_supervised!({StateStore, name: "store_b", path: tmp2, initial: %{items: []}})

    assert :ok = StateStore.apply_action("store_a", {:append, :records, %{"from" => "a"}})
    assert :ok = StateStore.apply_action("store_b", {:append, :items, %{"from" => "b"}})

    assert StateStore.snapshot("store_a") == %{records: [%{"from" => "a"}]}
    assert StateStore.snapshot("store_b") == %{items: [%{"from" => "b"}]}
  end
end
