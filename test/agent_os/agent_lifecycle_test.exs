defmodule AgentOS.AgentLifecycleTest do
  @moduledoc """
  Spec 042: the single lifecycle seam (pause/resume/delete/update_spend_cap/update_triggers).
  Hermetic — temp-dir StateStores, temp manifest/agent files, an injected TriggerArming process.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AgentOS.AgentLifecycle
  alias AgentOS.DeploymentRegistry
  alias AgentOS.Manifest
  alias AgentOS.StateStore
  alias AgentOS.TriggerArming

  @stores ~w(deployments spend_ledger provenance conformance judge_results
             security_review_results)

  setup do
    uniq = System.unique_integer([:positive])

    if Process.whereis(AgentOS.StateStoreRegistry) == nil do
      start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    end

    # Isolated map-stores per test.
    for store <- @stores do
      path = Path.join(System.tmp_dir!(), "#{store}_#{uniq}.db")
      start_supervised!({StateStore, name: store, path: path, initial: %{}}, id: store)
      on_exit(fn -> File.rm(path) end)
    end

    approvals_path = Path.join(System.tmp_dir!(), "approvals_#{uniq}.db")

    start_supervised!(
      {StateStore, name: "pending_approvals", path: approvals_path, initial: %{approvals: %{}}},
      id: "pending_approvals"
    )

    on_exit(fn -> File.rm(approvals_path) end)

    {:ok, uniq: uniq}
  end

  # Writes a manifest with the given time trigger to a temp file; returns the path.
  defp write_manifest(agent, at, cap \\ 1_000_000) do
    path = Path.join(System.tmp_dir!(), "#{agent}.md")

    # A representative generated manifest always has at least one grant (projection rejects
    # empty capabilities), so the serializer round-trips faithfully — mirror that here.
    File.write!(path, """
    ---
    purpose: "lifecycle test agent"
    triggers:
      - type: time
        at: "#{at}"
      - type: message
    grants:
      - connector: kv_append
        methods: ["append"]
    spend:
      cap: #{cap}
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    # Lifecycle test agent
    """)

    on_exit(fn -> File.rm(path) end)
    path
  end

  # Starts an injectable TriggerArming with captured schedule/cancel and returns {pid, parent-recv}.
  defp start_arming do
    parent = self()
    schedule_fn = fn message, ms -> send(parent, {:scheduled, message, ms}) && make_ref() end
    start_run_fn = fn opts -> send(parent, {:start_run, opts}) && :ok end
    cancel_fn = fn ref -> send(parent, {:cancelled, ref}) && false end

    start_supervised!(
      {TriggerArming,
       name: nil, schedule_fn: schedule_fn, start_run_fn: start_run_fn, cancel_fn: cancel_fn}
    )
  end

  # --- US1: pause / resume ---

  describe "pause/1" do
    test "marks a deployed agent inactive" do
      agent = "pause_ok_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "08:30")
      :ok = DeploymentRegistry.record_deployment(agent, path, :reviewed_human)

      assert :ok = AgentLifecycle.pause(agent)
      refute DeploymentRegistry.deployed_and_active?(agent)
      # Record preserved (not deleted), just inactive.
      assert DeploymentRegistry.get(agent).active == false
    end

    test "errors for an agent that was never deployed" do
      assert {:error, :not_deployed} = AgentLifecycle.pause("ghost_#{System.unique_integer()}")
    end
  end

  describe "resume/2" do
    test "reactivates preserving deployed_at/provenance, without firing startup, and re-arms" do
      agent = "resume_ok_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "08:30")
      :ok = DeploymentRegistry.record_deployment(agent, path, :reviewed_human)
      original = DeploymentRegistry.get(agent)
      :ok = DeploymentRegistry.mark_inactive(agent)

      arming = start_arming()
      # Drain any boot arming from the injected process (none active at boot here).

      assert :ok = AgentLifecycle.resume(agent, trigger_server: arming)

      resumed = DeploymentRegistry.get(agent)
      assert resumed.active == true
      assert resumed.deployed_at == original.deployed_at
      assert resumed.provenance == original.provenance

      # Re-armed the time trigger; the startup path did not run (no startup trigger declared).
      assert_receive {:scheduled, {:fire, ^agent, "08:30"}, _ms}
      refute_receive {:start_run, [trigger: "startup", agent: ^agent]}
    end

    test "errors when the agent was never deployed" do
      assert {:error, :not_deployed} = AgentLifecycle.resume("ghost_#{System.unique_integer()}")
    end

    test "errors loudly when the manifest file is missing" do
      agent = "resume_missing_#{System.unique_integer([:positive])}"
      path = Path.join(System.tmp_dir!(), "gone_#{agent}.md")
      :ok = DeploymentRegistry.record_deployment(agent, path, :reviewed_human)
      :ok = DeploymentRegistry.mark_inactive(agent)

      log =
        capture_log(fn ->
          assert {:error, :manifest_missing} = AgentLifecycle.resume(agent)
        end)

      assert log =~ agent
      # Left paused, not reactivated.
      refute DeploymentRegistry.deployed_and_active?(agent)
    end
  end

  # --- US2: delete ---

  describe "delete/2" do
    test "removes record, files, per-agent state, and owned pending approvals" do
      agent = "del_#{System.unique_integer([:positive])}"
      manifest_path = write_manifest(agent, "08:30")
      :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)

      # A temp agents/<name> code dir.
      agents_dir = Path.join(System.tmp_dir!(), "agents_#{System.unique_integer([:positive])}")
      agent_dir = Path.join(agents_dir, agent)
      File.mkdir_p!(agent_dir)
      File.write!(Path.join(agent_dir, "main.py"), "print('hi')")
      on_exit(fn -> File.rm_rf(agents_dir) end)

      # Seed per-agent state in each store.
      for store <- ~w(spend_ledger provenance conformance judge_results
                      security_review_results) do
        :ok = StateStore.apply_action(store, {:put, agent, %{seeded: true}})
      end

      # Two approvals: one owned (recipient == agent), one belonging to another agent.
      :ok =
        StateStore.apply_action(
          "pending_approvals",
          {:put, :approvals,
           %{
             "ref_mine" => %{action: %{type: "discord_notify", recipient: agent}, grant: %{}},
             "ref_other" => %{
               action: %{type: "discord_notify", recipient: "someone_else"},
               grant: %{}
             }
           }}
        )

      arming = start_arming()

      assert :ok =
               AgentLifecycle.delete(agent,
                 manifest_path: manifest_path,
                 agents_dir: agents_dir,
                 trigger_server: arming
               )

      # Record gone.
      assert DeploymentRegistry.get(agent) == nil
      # Files gone.
      refute File.exists?(agent_dir)
      refute File.exists?(manifest_path)
      # Per-agent state gone.
      for store <- ~w(spend_ledger provenance conformance judge_results
                      security_review_results) do
        refute Map.has_key?(StateStore.snapshot(store), agent)
      end

      # Owned approval swept; the other agent's approval preserved.
      remaining = Map.get(StateStore.snapshot("pending_approvals"), :approvals, %{})
      refute Map.has_key?(remaining, "ref_mine")
      assert Map.has_key?(remaining, "ref_other")
    end

    test "tolerates already-missing files and is idempotent" do
      agent = "del_partial_#{System.unique_integer([:positive])}"
      manifest_path = Path.join(System.tmp_dir!(), "never_#{agent}.md")

      agents_dir =
        Path.join(System.tmp_dir!(), "agents_never_#{System.unique_integer([:positive])}")

      # Neither the manifest nor the agents dir exists.

      arming = start_arming()

      assert :ok =
               AgentLifecycle.delete(agent,
                 manifest_path: manifest_path,
                 agents_dir: agents_dir,
                 trigger_server: arming
               )

      # A second delete is also a harmless no-op.
      assert :ok =
               AgentLifecycle.delete(agent,
                 manifest_path: manifest_path,
                 agents_dir: agents_dir,
                 trigger_server: arming
               )
    end
  end

  # --- US3: spend cap ---

  describe "update_spend_cap/3" do
    test "writes the cap in micro-dollars and round-trips through Manifest.load" do
      agent = "cap_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "08:30", 1_000_000)

      assert :ok = AgentLifecycle.update_spend_cap(agent, 2, manifest_path: path)

      {:ok, manifest} = Manifest.load(path)
      assert manifest.spend.cap == 2_000_000
    end

    test "accepts fractional dollars and rounds to micro-dollars" do
      agent = "cap_frac_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "08:30")

      assert :ok = AgentLifecycle.update_spend_cap(agent, 0.5, manifest_path: path)
      {:ok, manifest} = Manifest.load(path)
      assert manifest.spend.cap == 500_000
    end

    test "rejects zero, negative, and non-numeric with no file change" do
      agent = "cap_bad_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "08:30", 1_000_000)
      before = File.read!(path)

      assert {:error, :invalid_cap} =
               AgentLifecycle.update_spend_cap(agent, 0, manifest_path: path)

      assert {:error, :invalid_cap} =
               AgentLifecycle.update_spend_cap(agent, -3, manifest_path: path)

      assert {:error, :invalid_cap} =
               AgentLifecycle.update_spend_cap(agent, "lots", manifest_path: path)

      assert File.read!(path) == before
    end
  end

  # --- US4: schedule ---

  describe "update_triggers/3" do
    test "changes a time trigger's at, preserving other triggers, and re-arms the new time" do
      agent = "trig_time_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "09:00")
      :ok = DeploymentRegistry.record_deployment(agent, path, :reviewed_human)

      arming = start_arming()
      # Drain the boot-arming of the already-active record at 09:00.
      assert_receive {:scheduled, {:fire, ^agent, "09:00"}, _}

      assert :ok =
               AgentLifecycle.update_triggers(
                 agent,
                 [%{type: :time, at: "10:00"}, %{type: :message}],
                 manifest_path: path,
                 trigger_server: arming
               )

      {:ok, manifest} = Manifest.load(path)
      assert manifest.triggers == [%{type: :time, at: "10:00"}, %{type: :message}]

      # Re-armed for the new time; old 09:00 never re-scheduled.
      assert_receive {:scheduled, {:fire, ^agent, "10:00"}, _}
      refute_receive {:scheduled, {:fire, ^agent, "09:00"}, _}
    end

    test "accepts string-keyed form-shaped entries and round-trips every type" do
      agent = "trig_all_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "09:00")

      triggers = [
        %{"type" => "startup"},
        %{"type" => "time", "at" => "07:30"},
        %{"type" => "event", "name" => "bookmark_saved"},
        %{"type" => "message"}
      ]

      assert :ok = AgentLifecycle.update_triggers(agent, triggers, manifest_path: path)

      {:ok, manifest} = Manifest.load(path)

      assert manifest.triggers == [
               %{type: :startup},
               %{type: :time, at: "07:30"},
               %{type: :event, name: "bookmark_saved"},
               %{type: :message}
             ]
    end

    test "converting a time trigger to another type stops the armed timer" do
      agent = "trig_retype_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "09:00")
      :ok = DeploymentRegistry.record_deployment(agent, path, :reviewed_human)

      arming = start_arming()
      assert_receive {:scheduled, {:fire, ^agent, "09:00"}, _}

      # time → message: the old daily timer must be cancelled and nothing new armed.
      assert :ok =
               AgentLifecycle.update_triggers(agent, [%{type: :message}],
                 manifest_path: path,
                 trigger_server: arming
               )

      assert_receive {:cancelled, _ref}
      refute_receive {:scheduled, _, _}

      {:ok, manifest} = Manifest.load(path)
      assert manifest.triggers == [%{type: :message}]
    end

    test "adding a time trigger to a previously time-less agent arms it immediately" do
      agent = "trig_add_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "09:00")
      # Start from a startup-only manifest (the user's real-world case).
      assert :ok = AgentLifecycle.update_triggers(agent, [%{type: :startup}], manifest_path: path)
      :ok = DeploymentRegistry.record_deployment(agent, path, :reviewed_human)

      arming = start_arming()
      # Boot arming fires startup once (deploy/boot path), but arms no timer.
      refute_receive {:scheduled, _, _}

      assert :ok =
               AgentLifecycle.update_triggers(
                 agent,
                 [%{type: :startup}, %{type: :time, at: "11:15"}],
                 manifest_path: path,
                 trigger_server: arming
               )

      assert_receive {:scheduled, {:fire, ^agent, "11:15"}, _}
    end

    test "keeping a startup trigger does NOT fire it on edit" do
      agent = "trig_startup_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "09:00")
      :ok = DeploymentRegistry.record_deployment(agent, path, :reviewed_human)

      arming = start_arming()
      assert_receive {:scheduled, {:fire, ^agent, "09:00"}, _}

      assert :ok =
               AgentLifecycle.update_triggers(agent, [%{type: :startup}],
                 manifest_path: path,
                 trigger_server: arming
               )

      # Startup fires only at deploy completion and boot — never from an edit.
      refute_receive {:start_run, _}
    end

    test "an empty list is allowed — the agent becomes inert, not an error" do
      agent = "trig_empty_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "09:00")

      assert :ok = AgentLifecycle.update_triggers(agent, [], manifest_path: path)

      {:ok, manifest} = Manifest.load(path)
      assert manifest.triggers == []
    end

    test "rejects invalid entries atomically with no file change" do
      agent = "trig_bad_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "09:00")
      before = File.read!(path)

      # Invalid time.
      assert {:error, {:invalid_time, "25:00"}} =
               AgentLifecycle.update_triggers(agent, [%{type: :time, at: "25:00"}],
                 manifest_path: path
               )

      # Missing/blank event name.
      assert {:error, :invalid_event_name} =
               AgentLifecycle.update_triggers(agent, [%{type: :event, name: "  "}],
                 manifest_path: path
               )

      # Unknown type.
      assert {:error, {:unknown_trigger_type, "cron"}} =
               AgentLifecycle.update_triggers(agent, [%{"type" => "cron"}], manifest_path: path)

      # One bad entry poisons the whole edit, even alongside valid ones.
      assert {:error, {:invalid_time, "noon"}} =
               AgentLifecycle.update_triggers(
                 agent,
                 [%{type: :message}, %{type: :time, at: "noon"}],
                 manifest_path: path
               )

      assert File.read!(path) == before
    end

    test "rejects duplicate triggers with no file change" do
      agent = "trig_dup_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "09:00")
      before = File.read!(path)

      assert {:error, :duplicate_triggers} =
               AgentLifecycle.update_triggers(
                 agent,
                 [%{type: :message}, %{"type" => "message"}],
                 manifest_path: path
               )

      assert {:error, :duplicate_triggers} =
               AgentLifecycle.update_triggers(
                 agent,
                 [%{type: :time, at: "08:00"}, %{type: :time, at: "08:00"}],
                 manifest_path: path
               )

      assert File.read!(path) == before
    end
  end

  describe "run_now/2" do
    test "starts one manual run for a deployed-active agent" do
      agent = "run_now_ok_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "08:30")
      :ok = DeploymentRegistry.record_deployment(agent, path, :reviewed_human)

      parent = self()
      start_run_fn = fn opts -> send(parent, {:start_run, opts}) && :ok end

      assert :ok = AgentLifecycle.run_now(agent, start_run_fn: start_run_fn)
      assert_receive {:start_run, opts}
      assert opts[:agent] == agent
      assert opts[:trigger] == "manual"
    end

    test "refuses a paused agent and a never-deployed agent without starting anything" do
      agent = "run_now_paused_#{System.unique_integer([:positive])}"
      path = write_manifest(agent, "08:30")
      :ok = DeploymentRegistry.record_deployment(agent, path, :reviewed_human)
      :ok = AgentLifecycle.pause(agent)

      start_run_fn = fn _opts -> flunk("run must not start") end

      assert {:error, :not_active} = AgentLifecycle.run_now(agent, start_run_fn: start_run_fn)

      assert {:error, :not_active} =
               AgentLifecycle.run_now("ghost_#{System.unique_integer()}",
                 start_run_fn: start_run_fn
               )
    end
  end

  describe "system agents (config :agent_os, :system_agents)" do
    setup do
      previous = Application.get_env(:agent_os, :system_agents, [])
      Application.put_env(:agent_os, :system_agents, ["sys_probe"])
      on_exit(fn -> Application.put_env(:agent_os, :system_agents, previous) end)
      :ok
    end

    test "every lifecycle mutation refuses a system agent with no side effects" do
      agent = "sys_probe"
      path = write_manifest(agent, "08:30")
      :ok = DeploymentRegistry.record_deployment(agent, path, :reviewed_human)
      before = File.read!(path)

      assert AgentLifecycle.system_agent?(agent)
      assert {:error, :system_agent} = AgentLifecycle.pause(agent)

      assert {:error, :system_agent} =
               AgentLifecycle.run_now(agent, start_run_fn: fn _ -> flunk("must not run") end)

      assert {:error, :system_agent} = AgentLifecycle.resume(agent, manifest_path: path)
      assert {:error, :system_agent} = AgentLifecycle.delete(agent, manifest_path: path)

      assert {:error, :system_agent} =
               AgentLifecycle.update_spend_cap(agent, 2.0, manifest_path: path)

      assert {:error, :system_agent} =
               AgentLifecycle.update_triggers(agent, [%{type: :message}], manifest_path: path)

      # Nothing was touched: manifest byte-identical, deployment record still active.
      assert File.read!(path) == before
      assert DeploymentRegistry.deployed_and_active?(agent)
    end

    test "non-system agents are unaffected by the config" do
      refute AgentLifecycle.system_agent?("some_generated_agent")
    end
  end
end
