defmodule AgentOS.TriggerArmingTest do
  @moduledoc """
  T011: at boot the substrate reads the deployment registry and arms each active
  agent's declared time triggers from its manifest (FR-007). A record whose
  manifest is missing is logged loudly and marked inactive — never a crash.
  Missed windows are never fired retroactively (no catch-up).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AgentOS.DeploymentRegistry
  alias AgentOS.StateStore
  alias AgentOS.TriggerArming

  setup do
    uniq = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "deployments_#{uniq}.db")

    if Process.whereis(AgentOS.StateStoreRegistry) == nil do
      start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    end

    start_supervised!({StateStore, name: "deployments", path: path, initial: %{}})
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  # Writes a manifest with a time trigger to a temp path and returns the path.
  defp write_time_manifest(agent_name, at) do
    path = Path.join(System.tmp_dir!(), "#{agent_name}.md")

    File.write!(path, """
    ---
    purpose: "arming test agent"
    triggers:
      - type: time
        at: "#{at}"
      - type: message
    grants: []
    spend:
      cap: 1000
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    # Arming test agent
    """)

    on_exit(fn -> File.rm(path) end)
    path
  end

  # Captures schedule requests {message, ms} and start_run invocations in the test
  # process mailbox so arming can be driven without real timers.
  defp capture_fns do
    parent = self()

    schedule_fn = fn message, ms ->
      send(parent, {:scheduled, message, ms})
      make_ref()
    end

    start_run_fn = fn opts ->
      send(parent, {:start_run, opts})
      :ok
    end

    {schedule_fn, start_run_fn}
  end

  # Writes a manifest with a startup trigger and returns its path.
  defp write_startup_manifest(agent_name) do
    path = Path.join(System.tmp_dir!(), "#{agent_name}.md")

    File.write!(path, """
    ---
    purpose: "startup test agent"
    triggers:
      - type: startup
    grants: []
    spend:
      cap: 1000
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    # Startup test agent
    """)

    on_exit(fn -> File.rm(path) end)
    path
  end

  test "fire_startup runs a startup-triggered active agent exactly once" do
    agent = "startup_ok_#{System.unique_integer([:positive])}"
    manifest_path = write_startup_manifest(agent)
    :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)

    {_schedule_fn, start_run_fn} = capture_fns()

    assert :ok = TriggerArming.fire_startup(agent, manifest_path, start_run_fn: start_run_fn)

    assert_receive {:start_run, opts}
    assert opts[:trigger] == "startup"
    assert opts[:agent] == agent
  end

  test "fire_startup is a no-op for an agent without a startup trigger" do
    agent = "startup_none_#{System.unique_integer([:positive])}"
    manifest_path = write_time_manifest(agent, "08:30")
    :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)

    {_schedule_fn, start_run_fn} = capture_fns()

    assert :ok = TriggerArming.fire_startup(agent, manifest_path, start_run_fn: start_run_fn)
    refute_receive {:start_run, _opts}
  end

  test "fire_startup does not run an inactive (undeployed) agent" do
    agent = "startup_inactive_#{System.unique_integer([:positive])}"
    manifest_path = write_startup_manifest(agent)
    # Deliberately NOT recorded in the registry → deployed_and_active? is false.

    {_schedule_fn, start_run_fn} = capture_fns()

    assert :ok = TriggerArming.fire_startup(agent, manifest_path, start_run_fn: start_run_fn)
    refute_receive {:start_run, _opts}
  end

  test "arms a per-agent time trigger from the manifest of each active record" do
    agent = "arm_ok_#{System.unique_integer([:positive])}"
    manifest_path = write_time_manifest(agent, "08:30")
    :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)

    {schedule_fn, start_run_fn} = capture_fns()
    now = ~U[2026-07-08 06:00:00Z]

    pid =
      start_supervised!(
        {TriggerArming,
         name: nil, schedule_fn: schedule_fn, start_run_fn: start_run_fn, now_fn: fn -> now end}
      )

    assert Process.alive?(pid)

    # Armed for the NEXT 08:30 — 2.5h from the injected now.
    expected_ms = TriggerArming.ms_until_next_time(now, ~T[08:30:00])
    assert_receive {:scheduled, {:fire, ^agent, "08:30"}, ^expected_ms}
    assert expected_ms == 2 * 60 * 60 * 1000 + 30 * 60 * 1000
  end

  test "firing runs the agent through start_run and re-arms the next occurrence" do
    agent = "arm_fire_#{System.unique_integer([:positive])}"
    manifest_path = write_time_manifest(agent, "08:30")
    :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)

    {schedule_fn, start_run_fn} = capture_fns()

    pid =
      start_supervised!(
        {TriggerArming, name: nil, schedule_fn: schedule_fn, start_run_fn: start_run_fn}
      )

    assert_receive {:scheduled, {:fire, ^agent, "08:30"}, _ms}

    # Drive the timer by hand.
    send(pid, {:fire, agent, "08:30"})

    assert_receive {:start_run, opts}
    assert opts[:trigger] == "time:08:30"
    assert opts[:agent] == agent

    # Re-armed for the following day.
    assert_receive {:scheduled, {:fire, ^agent, "08:30"}, _next_ms}
  end

  test "fire re-checks the registry — an agent marked inactive after arming never runs" do
    agent = "arm_inactive_#{System.unique_integer([:positive])}"
    manifest_path = write_time_manifest(agent, "09:00")
    :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)

    {schedule_fn, start_run_fn} = capture_fns()

    pid =
      start_supervised!(
        {TriggerArming, name: nil, schedule_fn: schedule_fn, start_run_fn: start_run_fn}
      )

    assert_receive {:scheduled, {:fire, ^agent, "09:00"}, _ms}

    # Deployment revoked between arming and the window.
    :ok = DeploymentRegistry.mark_inactive(agent)

    log =
      capture_log(fn ->
        send(pid, {:fire, agent, "09:00"})
        # Synchronize on the GenServer having processed the message.
        _ = :sys.get_state(pid)
      end)

    refute_receive {:start_run, _}
    assert log =~ agent
  end

  test "a record whose manifest file is missing is logged loudly and marked inactive, no crash" do
    agent = "arm_missing_#{System.unique_integer([:positive])}"
    missing_path = Path.join(System.tmp_dir!(), "nonexistent_#{agent}.md")
    :ok = DeploymentRegistry.record_deployment(agent, missing_path, :reviewed_human)

    {schedule_fn, start_run_fn} = capture_fns()

    log =
      capture_log(fn ->
        pid =
          start_supervised!(
            {TriggerArming, name: nil, schedule_fn: schedule_fn, start_run_fn: start_run_fn}
          )

        assert Process.alive?(pid)
        _ = :sys.get_state(pid)
      end)

    assert log =~ agent
    assert log =~ "missing"

    # Marked inactive rather than silently skipped.
    refute DeploymentRegistry.deployed_and_active?(agent)
    refute_receive {:scheduled, _, _}
  end

  test "inactive records are not armed at boot" do
    agent = "arm_boot_inactive_#{System.unique_integer([:positive])}"
    manifest_path = write_time_manifest(agent, "10:00")
    :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)
    :ok = DeploymentRegistry.mark_inactive(agent)

    {schedule_fn, start_run_fn} = capture_fns()

    start_supervised!(
      {TriggerArming, name: nil, schedule_fn: schedule_fn, start_run_fn: start_run_fn}
    )

    refute_receive {:scheduled, _, _}
  end

  test "disarm cancels every armed timer for an agent and forgets it" do
    agent = "disarm_#{System.unique_integer([:positive])}"
    manifest_path = write_time_manifest(agent, "08:30")
    :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)

    parent = self()
    schedule_fn = fn message, ms -> send(parent, {:scheduled, message, ms}) && make_ref() end
    start_run_fn = fn opts -> send(parent, {:start_run, opts}) && :ok end
    cancel_fn = fn ref -> send(parent, {:cancelled, ref}) && false end

    pid =
      start_supervised!(
        {TriggerArming,
         name: nil, schedule_fn: schedule_fn, start_run_fn: start_run_fn, cancel_fn: cancel_fn}
      )

    assert_receive {:scheduled, {:fire, ^agent, "08:30"}, _ms}

    assert :ok = TriggerArming.disarm(agent, pid)
    # The armed timer ref was cancelled.
    assert_receive {:cancelled, ref} when is_reference(ref)

    # A stale fire delivered after disarm neither re-arms nor is otherwise scheduled.
    send(pid, {:fire, agent, "08:30"})
    _ = :sys.get_state(pid)
    refute_receive {:scheduled, {:fire, ^agent, "08:30"}, _}
  end

  test "rearm cancels the old timer and arms the CURRENT manifest time" do
    agent = "rearm_#{System.unique_integer([:positive])}"
    manifest_path = write_time_manifest(agent, "08:30")
    :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)

    parent = self()
    schedule_fn = fn message, ms -> send(parent, {:scheduled, message, ms}) && make_ref() end
    start_run_fn = fn opts -> send(parent, {:start_run, opts}) && :ok end
    cancel_fn = fn ref -> send(parent, {:cancelled, ref}) && false end

    pid =
      start_supervised!(
        {TriggerArming,
         name: nil, schedule_fn: schedule_fn, start_run_fn: start_run_fn, cancel_fn: cancel_fn}
      )

    assert_receive {:scheduled, {:fire, ^agent, "08:30"}, _ms}

    # Simulate a schedule edit: rewrite the manifest to a new time, then rearm.
    File.write!(manifest_path, """
    ---
    purpose: "arming test agent"
    triggers:
      - type: time
        at: "10:00"
    grants: []
    spend:
      cap: 1000
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    # Arming test agent
    """)

    assert :ok = TriggerArming.rearm(agent, pid)

    # Old 08:30 timer cancelled; new 10:00 timer armed; old time never re-scheduled.
    assert_receive {:cancelled, _ref}
    assert_receive {:scheduled, {:fire, ^agent, "10:00"}, _ms}
    refute_receive {:scheduled, {:fire, ^agent, "08:30"}, _}
  end

  test "rearm after a time trigger is retyped away cancels the timer and arms nothing" do
    agent = "rearm_retype_#{System.unique_integer([:positive])}"
    manifest_path = write_time_manifest(agent, "08:30")
    :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)

    parent = self()
    schedule_fn = fn message, ms -> send(parent, {:scheduled, message, ms}) && make_ref() end
    start_run_fn = fn opts -> send(parent, {:start_run, opts}) && :ok end
    cancel_fn = fn ref -> send(parent, {:cancelled, ref}) && false end

    pid =
      start_supervised!(
        {TriggerArming,
         name: nil, schedule_fn: schedule_fn, start_run_fn: start_run_fn, cancel_fn: cancel_fn}
      )

    assert_receive {:scheduled, {:fire, ^agent, "08:30"}, _ms}

    # The user converts the daily trigger to message-only (trigger editing, spec 042).
    File.write!(manifest_path, """
    ---
    purpose: "arming test agent"
    triggers:
      - type: message
    grants: []
    spend:
      cap: 1000
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    # Arming test agent
    """)

    assert :ok = TriggerArming.rearm(agent, pid)

    # Old timer cancelled; no time trigger remains, so nothing is armed.
    assert_receive {:cancelled, _ref}
    refute_receive {:scheduled, _, _}
  end

  test "rearm on a paused (inactive) agent arms nothing" do
    agent = "rearm_paused_#{System.unique_integer([:positive])}"
    manifest_path = write_time_manifest(agent, "08:30")
    :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)

    parent = self()
    schedule_fn = fn message, ms -> send(parent, {:scheduled, message, ms}) && make_ref() end
    start_run_fn = fn opts -> send(parent, {:start_run, opts}) && :ok end
    cancel_fn = fn _ref -> false end

    pid =
      start_supervised!(
        {TriggerArming,
         name: nil, schedule_fn: schedule_fn, start_run_fn: start_run_fn, cancel_fn: cancel_fn}
      )

    assert_receive {:scheduled, {:fire, ^agent, "08:30"}, _ms}

    :ok = DeploymentRegistry.mark_inactive(agent)
    assert :ok = TriggerArming.rearm(agent, pid)

    refute_receive {:scheduled, _, _}
  end

  test "a stale fire delivered after disarm does not re-arm the schedule" do
    agent = "stale_#{System.unique_integer([:positive])}"
    manifest_path = write_time_manifest(agent, "09:00")
    :ok = DeploymentRegistry.record_deployment(agent, manifest_path, :reviewed_human)

    parent = self()
    schedule_fn = fn message, ms -> send(parent, {:scheduled, message, ms}) && make_ref() end
    start_run_fn = fn opts -> send(parent, {:start_run, opts}) && :ok end
    cancel_fn = fn _ref -> false end

    pid =
      start_supervised!(
        {TriggerArming,
         name: nil, schedule_fn: schedule_fn, start_run_fn: start_run_fn, cancel_fn: cancel_fn}
      )

    assert_receive {:scheduled, {:fire, ^agent, "09:00"}, _ms}
    :ok = TriggerArming.disarm(agent, pid)

    # A fire message that raced the cancel and arrived after disarm must be dropped, not re-armed.
    send(pid, {:fire, agent, "09:00"})
    _ = :sys.get_state(pid)
    refute_receive {:scheduled, {:fire, ^agent, "09:00"}, _}
  end

  test "no catch-up: ms_until_next_time always schedules the NEXT occurrence, strictly in the future" do
    # Window already passed today -> tomorrow.
    now = ~U[2026-07-08 12:00:00Z]
    ms = TriggerArming.ms_until_next_time(now, ~T[08:00:00])
    assert ms == 20 * 60 * 60 * 1000

    # Window exactly now -> tomorrow, never zero.
    ms_now = TriggerArming.ms_until_next_time(~U[2026-07-08 08:00:00Z], ~T[08:00:00])
    assert ms_now == 24 * 60 * 60 * 1000

    # Window later today -> today.
    ms_later = TriggerArming.ms_until_next_time(now, ~T[15:45:00])
    assert ms_later == 3 * 60 * 60 * 1000 + 45 * 60 * 1000
  end
end
