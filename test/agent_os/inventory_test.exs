defmodule AgentOS.InventoryTest do
  use ExUnit.Case, async: false

  alias AgentOS.Inventory
  alias AgentOS.StateStore

  setup do
    tmp_roster =
      Path.join(
        System.tmp_dir!(),
        "roster_inventory_#{System.unique_integer([:positive])}.term"
      )

    tmp_spend =
      Path.join(
        System.tmp_dir!(),
        "spend_ledger_inventory_#{System.unique_integer([:positive])}.term"
      )

    tmp_approvals =
      Path.join(
        System.tmp_dir!(),
        "pending_approvals_inventory_#{System.unique_integer([:positive])}.term"
      )

    on_exit(fn ->
      try do
        File.rm(tmp_roster)
      rescue
        _ -> :ok
      end

      try do
        File.rm(tmp_spend)
      rescue
        _ -> :ok
      end

      try do
        File.rm(tmp_approvals)
      rescue
        _ -> :ok
      end
    end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})

    start_supervised!(
      {StateStore, name: "roster_trust", path: tmp_roster, initial: %{records: []}}
    )

    start_supervised!({StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})

    start_supervised!(
      {StateStore, name: "pending_approvals", path: tmp_approvals, initial: %{approvals: %{}}}
    )

    {:ok, tmp_roster: tmp_roster, tmp_spend: tmp_spend, tmp_approvals: tmp_approvals}
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
    assert report =~ "GRANTS: ["
    assert report =~ "SPEND: $0.0 / $0.5 per daily"
    assert report =~ "Total Records: 1"
    assert report =~ "Last Digest: test digest text"
  end

  describe "spend visibility (User Story 3)" do
    test "renders spend from spend_ledger correctly and resets after rollover" do
      now = ~U[2026-06-29 12:00:00Z]

      # (a) seed spend_ledger with spent: 3
      :ok =
        StateStore.apply_action(
          "spend_ledger",
          {:put, "discovery", %{spent: 3, window_start: now}}
        )

      report_a = Inventory.render(manifest_path: "manifests/discovery.md", now: now)
      assert report_a =~ "SPEND: $0.000003 / $0.5 per daily"

      # (b) seed spent: 5, window_start: 25 hours ago -> resets to 0 on display
      past_time = DateTime.add(now, -25 * 3600, :second)

      :ok =
        StateStore.apply_action(
          "spend_ledger",
          {:put, "discovery", %{spent: 5, window_start: past_time}}
        )

      report_b = Inventory.render(manifest_path: "manifests/discovery.md", now: now)
      assert report_b =~ "SPEND: $0.0 / $0.5 per daily"
    end

    test "renders spend with empty ledger as 0" do
      now = ~U[2026-06-29 12:00:00Z]
      # empty ledger (discovery not present)
      report = Inventory.render(manifest_path: "manifests/discovery.md", now: now)
      assert report =~ "SPEND: $0.0 / $0.5 per daily"
    end
  end

  test "renders pending approvals on standing inventory" do
    mock_action = %AgentOS.ProposedAction{
      type: "external_send",
      recipient: "owner-inbox",
      method: "send",
      payload: %{"text" => "hello"}
    }

    mock_grant = %AgentOS.Manifest.Grant{
      connector: "external_send",
      recipients: ["owner-inbox"],
      methods: ["send"]
    }

    :ok =
      StateStore.apply_action(
        "pending_approvals",
        {:put, :approvals,
         %{"ref_42" => %{ref: "ref_42", action: mock_action, grant: mock_grant}}}
      )

    report = Inventory.render(manifest_path: "manifests/discovery.md")

    assert report =~ "Pending approvals:"
    assert report =~ "ref_42"
    assert report =~ "external_send → owner-inbox"
  end
end
