defmodule AgentOS.RunSupervisorTest do
  use ExUnit.Case, async: false

  alias AgentOS.RunSupervisor
  alias AgentOS.RunWorker
  alias AgentOS.StateStore

  setup do
    tmp_log =
      Path.join(
        System.tmp_dir!(),
        "run_log_super_#{System.unique_integer([:positive])}.md"
      )

    on_exit(fn ->
      File.rm(tmp_log)
    end)

    paths = AgentOS.TestHelper.start_mounts!()

    start_supervised!(RunSupervisor)

    {:ok, roster_path: paths.roster_path, log_path: tmp_log}
  end

  # --- Task 2: RunWorker Tests ---

  test "RunWorker.run_once/1 happy path runs python agent, validates and executes actions", %{
    log_path: log_path
  } do
    # Seed the roster store so the agent has input
    :ok =
      StateStore.apply_action(
        "roster_trust",
        {:append, :records, %{"signal" => "high", "text" => "valid news"}}
      )

    # Run the worker with the real python agent path
    assert :ok =
             RunWorker.run_once(
               agent_cmd: ".venv/bin/python",
               agent_args: ["agents/discovery/main.py"],
               run_log_path: log_path
             )

    # Check that state was mutated (the python agent emits actions based on roster input)
    # The effector creates an append_digest action that gets recorded as a digest record at v0
    snapshot = StateStore.snapshot("roster_trust")
    assert length(snapshot.records) == 2

    assert Enum.any?(snapshot.records, fn r ->
             Map.has_key?(r, "digest") and r["digest"] =~ "valid news"
           end)

    # Verify run-log entry
    assert File.exists?(log_path)
    log_content = File.read!(log_path)
    assert log_content =~ "status=ok"
    assert log_content =~ "actions=1"
  end

  test "RunWorker.run_once/1 error path logs status=error when PortRunner fails", %{
    log_path: log_path
  } do
    # Inject a failing command
    assert {:error, _} =
             RunWorker.run_once(
               agent_cmd: "bash",
               agent_args: ["-c", "exit 1"],
               run_log_path: log_path
             )

    # Verify run-log entry has error status
    assert File.exists?(log_path)
    log_content = File.read!(log_path)
    assert log_content =~ "status=error"
    assert log_content =~ "actions=0"
  end

  test "RunWorker.run_once/1 exit code classification (0, 137, non-zero, timeout)", %{
    log_path: log_path
  } do
    # 1. Test timeout (returns {:error, :timeout})
    assert {:error, :timeout} =
             RunWorker.run_once(
               agent_cmd: "sleep",
               agent_args: ["10"],
               timeout_ms: 100,
               run_log_path: log_path
             )

    assert File.read!(log_path) =~ "failure_cause=timeout"

    # 2. Test crash (exit 1)
    assert {:error, {:exit_status, 1}} =
             RunWorker.run_once(
               agent_cmd: "bash",
               agent_args: ["-c", "exit 1"],
               run_log_path: log_path
             )

    assert File.read!(log_path) =~ "exit_code=1 failure_cause=crash"

    # 3. Test OOM (exit 137)
    assert {:error, {:exit_status, 137}} =
             RunWorker.run_once(
               agent_cmd: "bash",
               agent_args: ["-c", "exit 137"],
               run_log_path: log_path
             )

    assert File.read!(log_path) =~ "exit_code=137 failure_cause=oom"
  end

  test "RunWorker.run_once/1 drops ungranted actions", %{log_path: log_path} do
    # Create a custom manifest with NO outputs/connectors allowed
    tmp_manifest =
      Path.join(
        System.tmp_dir!(),
        "discovery_empty_#{System.unique_integer([:positive])}.md"
      )

    on_exit(fn -> File.rm(tmp_manifest) end)

    File.write!(tmp_manifest, """
    ---
    purpose: "Empty manifest"
    owner: human
    supervision: restart-once-and-alert
    grants: []
    spend:
      cap: 5
      window: daily
      on_breach: kill
    ---
    """)

    # Seed roster
    :ok = StateStore.apply_action("roster_trust", {:append, :records, %{"text" => "news"}})

    # Run worker with the empty manifest
    assert :ok =
             RunWorker.run_once(
               agent_cmd: ".venv/bin/python",
               agent_args: ["agents/discovery/main.py"],
               manifest_path: tmp_manifest,
               run_log_path: log_path
             )

    # Verify no new record was created (it was dropped before effector)
    snapshot = StateStore.snapshot("roster_trust")
    assert length(snapshot.records) == 1

    # Verify log says actions=0 (since 1 proposed action was dropped)
    log_content = File.read!(log_path)
    assert log_content =~ "status=ok"
    assert log_content =~ "actions=0"
  end

  # --- Task 3: RunSupervisor Tests ---

  test "RunSupervisor success path: successful run is executed exactly once", %{
    log_path: log_path
  } do
    test_pid = self()

    worker_fn = fn _opts ->
      send(test_pid, :worker_called)
      :ok
    end

    assert :ok = RunSupervisor.start_run(worker_fn: worker_fn, run_log_path: log_path)

    # Assert worker called once
    assert_receive :worker_called, 500
    refute_receive :worker_called, 500
  end

  test "RunSupervisor crash-once path: fails first time, retried once, ends green", %{
    log_path: log_path
  } do
    test_pid = self()

    {:ok, agent_pid} = Agent.start_link(fn -> 0 end)

    worker_fn = fn _opts ->
      send(test_pid, :worker_called)
      attempts = Agent.get_and_update(agent_pid, fn count -> {count, count + 1} end)

      if attempts == 0 do
        {:error, :temporary_failure}
      else
        :ok
      end
    end

    assert :ok = RunSupervisor.start_run(worker_fn: worker_fn, run_log_path: log_path)

    assert_receive :worker_called, 500
    assert_receive :worker_called, 500
    refute_receive :worker_called, 500

    refute File.exists?(log_path) and File.read!(log_path) =~ "status=alert"
  end

  test "RunSupervisor crash-twice path: fails both times, triggers Alerter", %{
    log_path: log_path
  } do
    test_pid = self()

    worker_fn = fn _opts ->
      send(test_pid, :worker_called)
      {:error, :persistent_failure}
    end

    assert :ok = RunSupervisor.start_run(worker_fn: worker_fn, run_log_path: log_path)

    assert_receive :worker_called, 500
    assert_receive :worker_called, 500
    refute_receive :worker_called, 500

    # Wait a moment for Alerter to run asynchronously
    Process.sleep(100)

    # Assert Alerter log entry exists and contains the failure reason
    assert File.exists?(log_path)
    log_content = File.read!(log_path)
    assert log_content =~ "status=alert"
    assert log_content =~ ":persistent_failure"
  end

  describe "windowed spend cap (User Story 1)" do
    setup do
      agent_name = "spend_agent_#{System.unique_integer([:positive])}"
      tmp_manifest = Path.join(System.tmp_dir!(), "#{agent_name}.md")

      File.write!(tmp_manifest, """
      ---
      purpose: "Spend test manifest"
      owner: human
      supervision: restart-once-and-alert
      grants:
        - connector: kv_append
          recipients: ["http://example.com"]
          methods: ["POST"]
      spend:
        cap: 5
        window: daily
        on_breach: kill
      ---
      """)

      on_exit(fn ->
        File.rm(tmp_manifest)
      end)

      now = ~U[2026-06-29 12:00:00Z]

      {:ok, manifest_path: tmp_manifest, agent_name: agent_name, now: now}
    end

    test "(a) actions summing to exactly the cap execute and spend_ledger is updated", %{
      manifest_path: manifest_path,
      agent_name: agent_name,
      log_path: log_path,
      now: now
    } do
      # 5 actions of cost 1 = 5 (exactly cap)
      actions_json =
        Jason.encode!(%{
          "actions" =>
            List.duplicate(
              %{
                "type" => "kv_append",
                "recipient" => "http://example.com",
                "method" => "POST"
              },
              5
            )
        })

      # Run worker
      RunWorker.run_once(
        agent_cmd: "echo",
        agent_args: [actions_json],
        manifest_path: manifest_path,
        run_log_path: log_path,
        now: now
      )

      # Assert that ledger entry is updated to exactly the cap
      ledger = StateStore.snapshot("spend_ledger")
      entry = Map.get(ledger, agent_name)
      assert entry != nil
      assert entry.spent == 5
      assert DateTime.compare(entry.window_start, now) == :eq
    end

    test "(b) pre-seed spent=cap 25h ago, action permitted and window reset", %{
      manifest_path: manifest_path,
      agent_name: agent_name,
      log_path: log_path,
      now: now
    } do
      # Seed ledger with cap spent 25 hours ago
      past_time = DateTime.add(now, -25 * 3600, :second)

      StateStore.apply_action(
        "spend_ledger",
        {:put, agent_name, %{spent: 5, window_start: past_time}}
      )

      # 1 action of cost 1
      action_json =
        Jason.encode!(%{
          "actions" => [
            %{
              "type" => "kv_append",
              "recipient" => "http://example.com",
              "method" => "POST"
            }
          ]
        })

      # Run worker
      RunWorker.run_once(
        agent_cmd: "echo",
        agent_args: [action_json],
        manifest_path: manifest_path,
        run_log_path: log_path,
        now: now
      )

      # Assert that ledger entry has reset (spent is now only 1, the new run's cost)
      ledger = StateStore.snapshot("spend_ledger")
      entry = Map.get(ledger, agent_name)
      assert entry != nil
      assert entry.spent == 1
      assert DateTime.compare(entry.window_start, now) == :eq
    end

    test "(c) within window spend accumulates against existing window with no reset", %{
      manifest_path: manifest_path,
      agent_name: agent_name,
      log_path: log_path,
      now: now
    } do
      # Seed ledger with spent=2, 1 hour ago
      past_time = DateTime.add(now, -3600, :second)

      StateStore.apply_action(
        "spend_ledger",
        {:put, agent_name, %{spent: 2, window_start: past_time}}
      )

      # 1 action of cost 1
      action_json =
        Jason.encode!(%{
          "actions" => [
            %{
              "type" => "kv_append",
              "recipient" => "http://example.com",
              "method" => "POST"
            }
          ]
        })

      # Run worker
      RunWorker.run_once(
        agent_cmd: "echo",
        agent_args: [action_json],
        manifest_path: manifest_path,
        run_log_path: log_path,
        now: now
      )

      # Assert that ledger entry accumulated (spent is now 3, window_start is still past_time)
      ledger = StateStore.snapshot("spend_ledger")
      entry = Map.get(ledger, agent_name)
      assert entry != nil
      assert entry.spent == 3
      assert DateTime.compare(entry.window_start, past_time) == :eq
    end
  end

  describe "breach and supervision (User Story 2)" do
    setup do
      agent_name = "spend_agent_#{System.unique_integer([:positive])}"
      tmp_manifest = Path.join(System.tmp_dir!(), "#{agent_name}.md")

      File.write!(tmp_manifest, """
      ---
      purpose: "Spend test manifest"
      owner: human
      supervision: restart-once-and-alert
      grants:
        - connector: kv_append
          recipients: ["http://example.com"]
          methods: ["POST"]
      spend:
        cap: 5
        window: daily
        on_breach: kill
      ---
      """)

      on_exit(fn ->
        File.rm(tmp_manifest)
      end)

      now = ~U[2026-06-29 12:00:00Z]

      {:ok, manifest_path: tmp_manifest, agent_name: agent_name, now: now}
    end

    test "(a) over-cap run returns {:killed, :spend_breach}, drops batch, logs status=killed", %{
      manifest_path: manifest_path,
      agent_name: agent_name,
      log_path: log_path,
      now: now
    } do
      # Pre-seed ledger with 5 spent (already at cap)
      StateStore.apply_action("spend_ledger", {:put, agent_name, %{spent: 5, window_start: now}})

      # 1 action of cost 1
      action_json =
        Jason.encode!(%{
          "actions" => [
            %{
              "type" => "kv_append",
              "recipient" => "http://example.com",
              "method" => "POST"
            }
          ]
        })

      # Run worker - returns {:killed, :spend_breach}
      assert {:killed, :spend_breach} =
               RunWorker.run_once(
                 agent_cmd: "echo",
                 agent_args: [action_json],
                 manifest_path: manifest_path,
                 run_log_path: log_path,
                 now: now
               )

      # Ledger spent remains at 5
      ledger = StateStore.snapshot("spend_ledger")
      entry = Map.get(ledger, agent_name)
      assert entry.spent == 5

      # Run log contains status=killed failure_cause=spend_breach
      assert File.exists?(log_path)
      log_content = File.read!(log_path)
      assert log_content =~ "status=killed"
      assert log_content =~ "failure_cause=spend_breach"
    end

    test "(b) RunSupervisor.start_run with worker returning {:killed, :spend_breach} runs once, no alert",
         %{
           log_path: log_path
         } do
      test_pid = self()

      worker_fn = fn _opts ->
        send(test_pid, :worker_called)
        {:killed, :spend_breach}
      end

      # RunSupervisor.start_run should exit cleanly with no retry/alert
      assert :ok = RunSupervisor.start_run(worker_fn: worker_fn, run_log_path: log_path)

      # Assert worker called exactly once
      assert_receive :worker_called, 500
      refute_receive :worker_called, 500

      # Assert no alert is logged
      refute File.exists?(log_path) and File.read!(log_path) =~ "status=alert"
    end
  end
end
