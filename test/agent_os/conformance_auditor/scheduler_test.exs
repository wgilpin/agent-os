defmodule AgentOS.ConformanceAuditor.SchedulerTest do
  use ExUnit.Case, async: true

  alias AgentOS.ConformanceAuditor.Scheduler

  test "ms_until_next/2 calculates scheduled time correctly" do
    now = ~U[2026-06-30 08:00:00Z]
    assert Scheduler.ms_until_next(now, 9) == 3_600_000
    assert Scheduler.ms_until_next(now, 8) == 86_400_000
    assert Scheduler.ms_until_next(now, 7) == 82_800_000
  end

  test "scheduler fires run_fn and reschedules when receiving :fire" do
    test_pid = self()
    run_fn = fn -> send(test_pid, :fired) end

    pid = start_supervised!({Scheduler, [name: nil, run_fn: run_fn, run_hour: 8]})

    state1 = :sys.get_state(pid)
    assert is_reference(state1.timer_ref)
    assert is_integer(state1.next_ms)
    assert state1.next_ms > 0
    ref1 = state1.timer_ref

    send(pid, :fire)

    assert_receive :fired, 1000

    state2 = :sys.get_state(pid)
    assert is_reference(state2.timer_ref)
    assert state2.timer_ref != ref1
    assert is_integer(state2.next_ms)
    assert state2.next_ms > 0
  end
end
