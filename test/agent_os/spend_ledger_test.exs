defmodule AgentOS.SpendLedgerTest do
  use ExUnit.Case, async: true
  alias AgentOS.SpendLedger

  setup do
    start = ~U[2026-06-29 12:00:00Z]
    {:ok, start: start}
  end

  test "duration_seconds/1 returns 86_400 for :daily" do
    assert SpendLedger.duration_seconds(:daily) == 86_400
  end

  test "rolled_over?/3 returns false within the window", %{start: start} do
    # 1 hour after start
    now = DateTime.add(start, 3600, :second)
    refute SpendLedger.rolled_over?(start, now, :daily)
  end

  test "rolled_over?/3 returns true exactly at boundary and beyond", %{start: start} do
    # exactly 24 hours after start
    boundary = DateTime.add(start, 86_400, :second)
    assert SpendLedger.rolled_over?(start, boundary, :daily)

    # 25 hours after start
    later = DateTime.add(start, 90_000, :second)
    assert SpendLedger.rolled_over?(start, later, :daily)
  end

  test "current_entry/3 returns entry unchanged within the window", %{start: start} do
    entry = %{spent: 3, window_start: start}
    now = DateTime.add(start, 3600, :second)
    assert SpendLedger.current_entry(entry, now, :daily) == entry
  end

  test "current_entry/3 returns reset entry at or after boundary", %{start: start} do
    entry = %{spent: 3, window_start: start}
    now = DateTime.add(start, 86_400, :second)
    assert SpendLedger.current_entry(entry, now, :daily) == %{spent: 0, window_start: now}
  end

  test "current_entry/3 zeroes spend when several windows elapsed", %{start: start} do
    entry = %{spent: 5, window_start: start}
    now = DateTime.add(start, 86_400 * 3, :second)
    assert SpendLedger.current_entry(entry, now, :daily) == %{spent: 0, window_start: now}
  end
end
