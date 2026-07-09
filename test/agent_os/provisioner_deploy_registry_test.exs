defmodule AgentOS.ProvisionerDeployRegistryTest do
  @moduledoc """
  T007/T017: every successful deployment — direct or approval-resumed — writes a
  typed record to the durable deployment registry; blocked and denied deploys
  write nothing (FR-005, US2/US3).
  """
  use ExUnit.Case, async: false

  alias AgentOS.DeploymentRecord
  alias AgentOS.DeploymentRegistry
  alias AgentOS.Provisioner
  alias AgentOS.StateStore
  alias AgentOS.TriggerGateway

  setup do
    AgentOS.TestHelper.start_mounts!()
    :ok
  end

  # Writes a minimal grant-free manifest (in-envelope: read-only, no egress, low cap)
  # to a temp path and returns it.
  defp write_manifest(agent_name) do
    path = Path.join(System.tmp_dir!(), "#{agent_name}.md")

    File.write!(path, """
    ---
    purpose: "registry test agent"
    grants: []
    spend:
      cap: 50000
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    # Registry test agent
    """)

    on_exit(fn -> File.rm(path) end)
    path
  end

  # Creates agent code files so the code-hash gate passes, and seeds matching
  # pass verdicts for judge and security review.
  defp seed_green_agent(agent_name) do
    temp_dir = Path.join(System.tmp_dir!(), "agents_#{System.unique_integer([:positive])}")
    agent_dir = Path.join(temp_dir, agent_name)
    File.mkdir_p!(agent_dir)
    File.write!(Path.join(agent_dir, "main.py"), "main")
    File.write!(Path.join(agent_dir, "models.py"), "models")
    hash = :crypto.hash(:sha256, "main\nmodels") |> Base.encode16()

    on_exit(fn -> File.rm_rf!(temp_dir) end)

    :ok =
      StateStore.apply_action(
        "judge_results",
        {:put, agent_name, %{status: :pass, code_hash: hash}}
      )

    :ok =
      StateStore.apply_action(
        "security_review_results",
        {:put, agent_name,
         %AgentOS.Pipeline.Stage5.Verdict{
           status: :pass,
           reasoning: "ok",
           timestamp: DateTime.utc_now(),
           code_hash: hash
         }}
      )

    [spec_dir: temp_dir]
  end

  defp uniq_agent(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  describe "US3: direct deploy writes the registry" do
    test "dangerously_skip_review success writes an active record" do
      agent = uniq_agent("reg_direct")
      manifest_path = write_manifest(agent)
      opts = seed_green_agent(agent)

      assert {:ok, :dangerously_skipped} =
               Provisioner.deploy(manifest_path, :dangerously_skip_review, opts)

      assert %DeploymentRecord{} = record = DeploymentRegistry.get(agent)
      assert record.active == true
      assert record.manifest_path == manifest_path
      assert record.provenance == :dangerously_skipped
    end

    test "in-envelope review_if_risky success writes an active record" do
      agent = uniq_agent("reg_envelope")
      manifest_path = write_manifest(agent)
      opts = seed_green_agent(agent)

      assert {:ok, :skipped_in_envelope} =
               Provisioner.deploy(manifest_path, :review_if_risky, opts)

      assert %DeploymentRecord{provenance: :skipped_in_envelope, active: true} =
               DeploymentRegistry.get(agent)
    end

    test "blocked always_review deploy does NOT write a registry record" do
      agent = uniq_agent("reg_blocked")
      manifest_path = write_manifest(agent)
      opts = seed_green_agent(agent)

      assert {:blocked, _ref} = Provisioner.deploy(manifest_path, :always_review, opts)
      assert DeploymentRegistry.get(agent) == nil
    end

    test "gate-failed deploy does NOT write a registry record" do
      agent = uniq_agent("reg_gatefail")
      manifest_path = write_manifest(agent)
      # No verdicts seeded -> missing_verdict gate failure.
      assert {:error, {:gate_failed, :missing_verdict}} =
               Provisioner.deploy(manifest_path, :dangerously_skip_review, [])

      assert DeploymentRegistry.get(agent) == nil
    end
  end

  describe "US2: approval-resume writes the registry" do
    test "approving a parked deploy writes an active :reviewed_human record" do
      agent = uniq_agent("reg_approve")
      manifest_path = write_manifest(agent)
      opts = seed_green_agent(agent)

      assert {:blocked, ref} = Provisioner.deploy(manifest_path, :always_review, opts)
      assert DeploymentRegistry.get(agent) == nil

      run_log = Path.join(System.tmp_dir!(), "run_log_#{System.unique_integer([:positive])}.md")
      on_exit(fn -> File.rm(run_log) end)

      effector_fn = fn %{action: _action, grant: _grant} -> :ok end

      assert {:resolved, :approved} =
               TriggerGateway.submit_sync({:approval, :approve, ref},
                 effector_fn: effector_fn,
                 run_log_path: run_log
               )

      assert %DeploymentRecord{} = record = DeploymentRegistry.get(agent)
      assert record.active == true
      assert record.manifest_path == manifest_path
      assert record.provenance == :reviewed_human
    end

    test "denying a parked deploy leaves the registry untouched" do
      agent = uniq_agent("reg_deny")
      manifest_path = write_manifest(agent)
      opts = seed_green_agent(agent)

      assert {:blocked, ref} = Provisioner.deploy(manifest_path, :always_review, opts)

      run_log = Path.join(System.tmp_dir!(), "run_log_#{System.unique_integer([:positive])}.md")
      on_exit(fn -> File.rm(run_log) end)

      assert {:resolved, :denied} =
               TriggerGateway.submit_sync({:approval, :deny, ref}, run_log_path: run_log)

      assert DeploymentRegistry.get(agent) == nil
    end

    test "approving a NON-deploy action writes no deployment record" do
      # Park a generic (non-deploy) approval by hand, as the gate does for
      # runtime approval-required actions.
      ref = "ref_generic_#{System.unique_integer([:positive])}"

      action = %AgentOS.ProposedAction{
        type: "external_send",
        recipient: "owner-inbox",
        method: "send",
        payload: %{}
      }

      grant = %AgentOS.Manifest.Grant{connector: "external_send", recipients: nil, methods: nil}

      approvals = %{ref => %{ref: ref, action: action, grant: grant}}
      :ok = StateStore.apply_action("pending_approvals", {:put, :approvals, approvals})

      run_log = Path.join(System.tmp_dir!(), "run_log_#{System.unique_integer([:positive])}.md")
      on_exit(fn -> File.rm(run_log) end)

      effector_fn = fn %{action: _action, grant: _grant} -> :ok end

      assert {:resolved, :approved} =
               TriggerGateway.submit_sync({:approval, :approve, ref},
                 effector_fn: effector_fn,
                 run_log_path: run_log
               )

      assert DeploymentRegistry.get("owner-inbox") == nil
      assert DeploymentRegistry.list_active() == []
    end
  end
end
