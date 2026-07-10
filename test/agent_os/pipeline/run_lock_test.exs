defmodule AgentOS.Pipeline.RunLockTest do
  use ExUnit.Case, async: false

  alias AgentOS.Pipeline.RunLock

  setup do
    # Start an isolated, uniquely-named lock per test (async: false, but keep hermetic).
    name = :"run_lock_#{System.unique_integer([:positive])}"
    start_supervised!({RunLock, name: name})
    {:ok, lock: name}
  end

  test "first claim succeeds, second for same agent is busy", %{lock: lock} do
    assert :ok = RunLock.claim("alpha", lock)
    assert {:error, :busy} = RunLock.claim("alpha", lock)
  end

  test "release frees the agent and is idempotent", %{lock: lock} do
    assert :ok = RunLock.claim("alpha", lock)
    assert RunLock.busy?("alpha", lock)

    assert :ok = RunLock.release("alpha", lock)
    refute RunLock.busy?("alpha", lock)
    # Releasing again is a no-op.
    assert :ok = RunLock.release("alpha", lock)
    assert :ok = RunLock.claim("alpha", lock)
  end

  test "different agents are independent", %{lock: lock} do
    assert :ok = RunLock.claim("alpha", lock)
    assert :ok = RunLock.claim("beta", lock)
    assert {:error, :busy} = RunLock.claim("alpha", lock)
    assert RunLock.busy?("beta", lock)
  end

  test "calls against an unstarted lock are tolerant" do
    missing = :"run_lock_absent_#{System.unique_integer([:positive])}"
    # No process registered under this name: claim/release/busy? must not crash.
    assert :ok = RunLock.claim("ghost", missing)
    assert :ok = RunLock.release("ghost", missing)
    refute RunLock.busy?("ghost", missing)
  end
end
