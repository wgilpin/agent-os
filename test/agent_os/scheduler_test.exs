defmodule AgentOS.SchedulerTest do
  use ExUnit.Case, async: true

  alias AgentOS.Scheduler

  test "ms_until_next/2 calculates exactly 1 hour before scheduled time" do
    now = ~U[2026-06-27 06:00:00Z]
    assert Scheduler.ms_until_next(now, 7) == 3_600_000
  end

  test "ms_until_next/2 rolls over to tomorrow at scheduled time" do
    now = ~U[2026-06-27 07:00:00Z]
    assert Scheduler.ms_until_next(now, 7) == 86_400_000
  end

  test "ms_until_next/2 rolls over to tomorrow 1 hour after scheduled time" do
    now = ~U[2026-06-27 08:00:00Z]
    assert Scheduler.ms_until_next(now, 7) == 82_800_000
  end

  test "scheduler fires run_fn and reschedules when receiving :fire" do
    test_pid = self()
    run_fn = fn -> send(test_pid, :fired) end

    # Start the Scheduler under the test supervisor with no registered global name
    pid = start_supervised!({Scheduler, [name: nil, run_fn: run_fn, run_hour: 7]})

    # Initial state check
    state1 = :sys.get_state(pid)
    assert is_reference(state1.timer_ref)
    assert is_integer(state1.next_ms)
    assert state1.next_ms > 0
    ref1 = state1.timer_ref

    # Explicitly trigger the fire event
    send(pid, :fire)

    # Assert that the injected function is called
    assert_receive :fired, 1000

    # Assert that a new timer has been scheduled
    state2 = :sys.get_state(pid)
    assert is_reference(state2.timer_ref)
    assert state2.timer_ref != ref1
    assert is_integer(state2.next_ms)
    assert state2.next_ms > 0
  end

  test "run_now/1 trigger manual records trigger=manual in run log" do
    log_path = Path.join(System.tmp_dir!(), "manual_scheduler_test.md")
    on_exit(fn -> File.rm(log_path) end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})

    start_supervised!(
      {AgentOS.StateStore,
       name: "roster_trust",
       path: Path.join(System.tmp_dir!(), "manual_roster.term"),
       initial: %{records: []}}
    )

    # Start RunSupervisor to support manual runs
    start_supervised!(AgentOS.RunSupervisor)

    # Trigger manual execution
    AgentOS.Scheduler.run_now(:manual,
      run_log_path: log_path,
      agent_cmd: "bash",
      agent_args: ["-c", "echo '{\"actions\": []}'"]
    )

    # Sleep to allow supervisor's async run worker task to complete
    Process.sleep(100)

    assert File.exists?(log_path)
    log_content = File.read!(log_path)
    assert log_content =~ "status=ok"
    assert log_content =~ "trigger=manual"
  end

  test "scheduler daily trigger records trigger=timer in run log" do
    log_path = Path.join(System.tmp_dir!(), "timer_scheduler_test.md")
    on_exit(fn -> File.rm(log_path) end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})

    start_supervised!(
      {AgentOS.StateStore,
       name: "roster_trust",
       path: Path.join(System.tmp_dir!(), "timer_roster.term"),
       initial: %{records: []}}
    )

    # Start RunSupervisor
    start_supervised!(AgentOS.RunSupervisor)

    # Trigger via :fire message directly to the scheduler
    run_fn = fn ->
      AgentOS.RunSupervisor.start_run(
        run_log_path: log_path,
        agent_cmd: "bash",
        agent_args: ["-c", "echo '{\"actions\": []}'"]
      )
    end

    pid = start_supervised!({AgentOS.Scheduler, [name: nil, run_fn: run_fn, run_hour: 7]})

    send(pid, :fire)

    # Sleep to allow supervisor's async run worker task to complete
    Process.sleep(100)

    assert File.exists?(log_path)
    log_content = File.read!(log_path)
    assert log_content =~ "status=ok"
    assert log_content =~ "trigger=timer"
  end
end
