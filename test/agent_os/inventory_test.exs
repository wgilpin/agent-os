defmodule AgentOS.InventoryTest do
  use ExUnit.Case, async: false

  alias AgentOS.Inventory
  alias AgentOS.StateStore

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "roster_inventory_#{System.unique_integer([:positive])}.term"
      )

    on_exit(fn -> File.rm(tmp) end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({StateStore, name: "roster_trust", path: tmp, initial: %{records: []}})
    {:ok, tmp: tmp}
  end

  test "render/1 returns standing inventory text" do
    # Add a mock digest to RosterStore to check if inventory extracts it
    :ok =
      StateStore.apply_action(
        "roster_trust",
        {:append, :records, %{"digest" => "test digest text"}}
      )

    report = Inventory.render(manifest_path: "manifests/discovery.md")

    assert report =~ "Agent OS Standing Inventory"
    assert report =~ "PURPOSE: Surface high-signal"
    assert report =~ "CONNECTORS: [\"record_signal\"]"
    assert report =~ "SPEND CAP: 5"
    assert report =~ "Total Records: 1"
    assert report =~ "Last Digest: test digest text"
  end
end
