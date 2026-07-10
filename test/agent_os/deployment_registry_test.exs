defmodule AgentOS.DeploymentRegistryTest do
  @moduledoc """
  T002: The deployment registry — the sole writer to the "deployments" store —
  records typed deployment records, upserts on redeploy, and exposes the
  active-flag predicates that gate trigger dispatch (FR-005).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AgentOS.DeploymentRecord
  alias AgentOS.DeploymentRegistry
  alias AgentOS.StateStore

  setup do
    uniq = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "deployments_#{uniq}.db")

    # Isolated seeded store per test (Constitution IV — no shared durable state).
    if Process.whereis(AgentOS.StateStoreRegistry) == nil do
      start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    end

    start_supervised!({StateStore, name: "deployments", path: path, initial: %{}})
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "record_deployment writes a typed active DeploymentRecord" do
    assert :ok =
             DeploymentRegistry.record_deployment(
               "notifier",
               "manifests/notifier.md",
               :reviewed_human
             )

    assert %DeploymentRecord{} = record = DeploymentRegistry.get("notifier")
    assert record.agent_name == "notifier"
    assert record.manifest_path == "manifests/notifier.md"
    assert record.provenance == :reviewed_human
    assert record.active == true
    assert %DateTime{} = record.deployed_at
  end

  test "redeploy upserts the record — exactly one record per agent, no duplicates" do
    :ok =
      DeploymentRegistry.record_deployment("notifier", "manifests/notifier.md", :reviewed_human)

    :ok =
      DeploymentRegistry.record_deployment(
        "notifier",
        "manifests/notifier.md",
        :dangerously_skipped
      )

    snapshot = StateStore.snapshot("deployments")
    assert map_size(snapshot) == 1

    record = DeploymentRegistry.get("notifier")
    assert record.provenance == :dangerously_skipped
    assert record.active == true
  end

  test "redeploy reactivates an inactive record" do
    :ok =
      DeploymentRegistry.record_deployment("notifier", "manifests/notifier.md", :reviewed_human)

    :ok = DeploymentRegistry.mark_inactive("notifier")
    refute DeploymentRegistry.deployed_and_active?("notifier")

    :ok =
      DeploymentRegistry.record_deployment("notifier", "manifests/notifier.md", :reviewed_human)

    assert DeploymentRegistry.deployed_and_active?("notifier")
  end

  test "get returns nil for an agent that was never deployed" do
    assert DeploymentRegistry.get("ghost") == nil
  end

  test "list_active returns only active records" do
    :ok = DeploymentRegistry.record_deployment("alpha", "manifests/alpha.md", :reviewed_human)
    :ok = DeploymentRegistry.record_deployment("beta", "manifests/beta.md", :skipped_in_envelope)
    :ok = DeploymentRegistry.mark_inactive("beta")

    active = DeploymentRegistry.list_active()
    assert [%DeploymentRecord{agent_name: "alpha"}] = active
  end

  test "deployed_and_active? is false for absent and inactive agents, true for active" do
    refute DeploymentRegistry.deployed_and_active?("absent")

    :ok = DeploymentRegistry.record_deployment("alpha", "manifests/alpha.md", :reviewed_human)
    assert DeploymentRegistry.deployed_and_active?("alpha")

    :ok = DeploymentRegistry.mark_inactive("alpha")
    refute DeploymentRegistry.deployed_and_active?("alpha")
  end

  test "mark_inactive preserves the rest of the record" do
    :ok = DeploymentRegistry.record_deployment("alpha", "manifests/alpha.md", :reviewed_human)
    original = DeploymentRegistry.get("alpha")

    :ok = DeploymentRegistry.mark_inactive("alpha")
    updated = DeploymentRegistry.get("alpha")

    assert updated.active == false
    assert updated.manifest_path == original.manifest_path
    assert updated.provenance == original.provenance
    assert updated.deployed_at == original.deployed_at
  end

  test "mark_inactive on an absent agent warns and no-ops" do
    log =
      capture_log(fn ->
        assert :ok = DeploymentRegistry.mark_inactive("ghost")
      end)

    assert log =~ "ghost"
    assert DeploymentRegistry.get("ghost") == nil
  end

  test "mark_active flips active back to true, preserving the rest of the record" do
    :ok = DeploymentRegistry.record_deployment("alpha", "manifests/alpha.md", :reviewed_human)
    original = DeploymentRegistry.get("alpha")

    :ok = DeploymentRegistry.mark_inactive("alpha")
    refute DeploymentRegistry.deployed_and_active?("alpha")

    :ok = DeploymentRegistry.mark_active("alpha")
    updated = DeploymentRegistry.get("alpha")

    assert updated.active == true
    assert updated.manifest_path == original.manifest_path
    assert updated.provenance == original.provenance
    # Resume is not a redeploy: the original deployment timestamp is preserved.
    assert updated.deployed_at == original.deployed_at
  end

  test "mark_active on an absent agent warns and no-ops" do
    log =
      capture_log(fn ->
        assert :ok = DeploymentRegistry.mark_active("ghost")
      end)

    assert log =~ "ghost"
    assert DeploymentRegistry.get("ghost") == nil
  end

  test "delete removes the record entirely — agent reverts to never-deployed" do
    :ok = DeploymentRegistry.record_deployment("alpha", "manifests/alpha.md", :reviewed_human)
    assert DeploymentRegistry.deployed_and_active?("alpha")

    :ok = DeploymentRegistry.delete("alpha")

    assert DeploymentRegistry.get("alpha") == nil
    refute DeploymentRegistry.deployed_and_active?("alpha")
    assert StateStore.snapshot("deployments") == %{}
  end

  test "delete on an absent agent warns and no-ops" do
    log =
      capture_log(fn ->
        assert :ok = DeploymentRegistry.delete("ghost")
      end)

    assert log =~ "ghost"
    assert DeploymentRegistry.get("ghost") == nil
  end
end
