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

  test "RunWorker.run_once/1 happy path runs python agent via the tool channel", %{
    log_path: log_path
  } do
    # Stand up the broker UDS + deterministic model stub so the python agent drives the
    # tool-call channel end to end (no live model). The rail executes kv_append and
    # records to the transcript; run_worker sources the tally from it.
    AgentOS.TestHelper.start_broker_uds!(AgentOS.TestHelper.discovery_provider_fn())

    # Seed the roster store so the agent has input
    :ok =
      StateStore.apply_action(
        "roster_trust",
        {:append, :records, %{"signal" => "high", "text" => "valid news"}}
      )

    # Run the worker with the real python agent path
    assert :ok =
             RunWorker.run_once(
               agent_cmd: System.get_env("PYTHON_BIN") || ".venv/bin/python",
               agent_args: ["agents/discovery/main.py"],
               run_log_path: log_path
             )

    # The kv_append tool call executed by the rail appended a digest to roster_trust.
    snapshot = StateStore.snapshot("roster_trust")
    assert length(snapshot.records) == 2

    assert Enum.any?(snapshot.records, fn r ->
             Map.has_key?(r, "digest") and r["digest"] =~ "valid news"
           end)

    # Verify run-log entry (tally sourced from the action transcript)
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
      cap: 500000
      window: daily
      on_breach: kill
    ---
    """)

    AgentOS.TestHelper.start_broker_uds!(AgentOS.TestHelper.discovery_provider_fn())

    # Seed roster
    :ok = StateStore.apply_action("roster_trust", {:append, :records, %{"text" => "news"}})

    # Run worker with the empty manifest: the model's kv_append tool call is ungranted,
    # so the rail rejects it (records :rejected) and nothing is executed.
    assert :ok =
             RunWorker.run_once(
               agent_cmd: System.get_env("PYTHON_BIN") || ".venv/bin/python",
               agent_args: ["agents/discovery/main.py"],
               manifest_path: tmp_manifest,
               run_log_path: log_path
             )

    # Verify no new record was created (the tool call was rejected by the rail)
    snapshot = StateStore.snapshot("roster_trust")
    assert length(snapshot.records) == 1

    # Verify log says actions=0 (the proposed tool call was rejected, not granted)
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

  # NOTE: Spend *charging* and window rollover moved off run_worker onto the broker
  # under the tool-channel cutover. That behaviour is covered at its new home:
  # windowing in spend_ledger_test.exs (current_entry/3) and metering/breach in
  # inference_broker_test.exs (T006 a/d/e, T014). run_worker only reads the ledger to
  # decide a breach — exercised below and in run_worker_transcript_test.exs (US3).

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
        cap: 5000
        window: daily
        on_breach: kill
      ---
      """)

      original_registry = AgentOS.Connector.registry()

      Application.put_env(:agent_os, :connector_registry, %{
        "kv_append" => %{
          name: "kv_append",
          mutating?: true,
          requires_deploy_consent?: false,
          requires_runtime_approval?: false,
          credential: nil,
          cost: 1000
        }
      })

      on_exit(fn ->
        File.rm(tmp_manifest)
        Application.put_env(:agent_os, :connector_registry, original_registry)
      end)

      now = ~U[2026-06-29 12:00:00Z]

      {:ok, manifest_path: tmp_manifest, agent_name: agent_name, now: now}
    end

    test "(a) pre-run ledger at/over cap returns {:killed, :spend_breach}, logs status=killed", %{
      manifest_path: manifest_path,
      agent_name: agent_name,
      log_path: log_path,
      now: now
    } do
      # Pre-seed ledger at cap (as the broker would have charged in a prior/this run).
      # run_worker's pre-check breach fires before the agent is even spawned.
      StateStore.apply_action(
        "spend_ledger",
        {:put, agent_name, %{spent: 5000, window_start: now}}
      )

      assert {:killed, :spend_breach} =
               RunWorker.run_once(
                 agent_cmd: "echo",
                 agent_args: [~s({"outcome":"completed","reason":"x"})],
                 manifest_path: manifest_path,
                 run_log_path: log_path,
                 now: now
               )

      # Ledger spent is untouched by run_worker (it only reads).
      ledger = StateStore.snapshot("spend_ledger")
      entry = Map.get(ledger, agent_name)
      assert entry.spent == 5000

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
