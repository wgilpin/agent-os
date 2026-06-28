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
end
