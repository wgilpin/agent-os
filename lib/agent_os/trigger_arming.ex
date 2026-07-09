defmodule AgentOS.TriggerArming do
  @moduledoc """
  Boot-time re-arming of per-agent time triggers from the deployment registry
  (FR-007).

  On init, reads every active `AgentOS.DeploymentRecord`, loads its manifest, and
  arms a self-rescheduling daily timer for each declared `%{type: :time, at: "HH:MM"}`
  trigger. Event and message triggers need no arming — they are dispatched on demand
  through `AgentOS.TriggerGateway`, which gates on the same registry.

  Behavior contracts:
    * A record whose manifest file is missing is logged loudly and marked inactive —
      boot never crashes and never skips silently (Constitution VI).
    * The registry is re-checked at fire time, so a deployment revoked after arming
      never runs.
    * No catch-up: arming always schedules the NEXT occurrence; windows missed while
      powered off are not fired retroactively.

  The legacy config-driven discovery schedule (`AgentOS.Scheduler`) is intentionally
  left untouched and runs alongside this module (research.md R4).
  """

  use GenServer
  require Logger

  @doc """
  Starts the TriggerArming GenServer.

  Options (all injectable for hermetic tests):
    * `:name` — process registration (default `#{inspect(__MODULE__)}`; nil to skip).
    * `:list_active_fn` — source of active records (default `DeploymentRegistry.list_active/0`).
    * `:registry_fn` — fire-time predicate (default `DeploymentRegistry.deployed_and_active?/1`).
    * `:manifest_load_fn` — manifest loader (default `AgentOS.Manifest.load/1`).
    * `:start_run_fn` — run starter (default `AgentOS.RunSupervisor.start_run/1`).
    * `:schedule_fn` — timer scheduler (default `Process.send_after(self(), msg, ms)`).
    * `:cancel_fn` — timer canceller (default `Process.cancel_timer/1`).
    * `:get_record_fn` — single-record lookup for re-arming (default `DeploymentRegistry.get/1`).
    * `:now_fn` — clock (default `DateTime.utc_now/0`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts_without_name} = Keyword.pop(opts, :name, __MODULE__)

    GenServer.start_link(
      __MODULE__,
      opts_without_name,
      [name: name] |> Enum.reject(fn {_, v} -> is_nil(v) end)
    )
  end

  @doc """
  Cancels every armed timer for `agent_name` and forgets it — used when an agent is
  deleted so a stale daily timer can never fire again. Synchronous. Safe (no-op) for an
  agent that has nothing armed.
  """
  @spec disarm(String.t(), GenServer.server()) :: :ok
  def disarm(agent_name, server \\ __MODULE__) when is_binary(agent_name) do
    GenServer.call(server, {:disarm, agent_name})
  end

  @doc """
  Cancels the agent's currently-armed timers and re-arms from its CURRENT manifest — used
  after a schedule edit (new `at`) or on resume. Only arms if the deployment record exists
  and is active; a paused/deleted agent ends up with no armed timers. Synchronous.
  """
  @spec rearm(String.t(), GenServer.server()) :: :ok
  def rearm(agent_name, server \\ __MODULE__) when is_binary(agent_name) do
    GenServer.call(server, {:rearm, agent_name})
  end

  @doc """
  Fires one startup run for `agent_name` if its manifest declares a `%{type: :startup}`
  trigger and the agent is currently deployed and active. Called at deploy completion
  (both the direct and approval-resume paths) and once per agent at boot re-arming, so
  "when the agent starts" fires when the agent becomes live and again after a power
  cycle. No-op when there is no startup trigger.

  Options (injectable for hermetic tests): `:registry_fn`, `:manifest_load_fn`,
  `:start_run_fn` — same defaults as `start_link/1`.
  """
  @spec fire_startup(String.t(), String.t(), keyword()) :: :ok
  def fire_startup(agent_name, manifest_path, opts \\ []) do
    registry_fn =
      Keyword.get(opts, :registry_fn, &AgentOS.DeploymentRegistry.deployed_and_active?/1)

    manifest_load_fn = Keyword.get(opts, :manifest_load_fn, &AgentOS.Manifest.load/1)
    start_run_fn = Keyword.get(opts, :start_run_fn, &AgentOS.RunSupervisor.start_run/1)

    with {:ok, manifest} <- manifest_load_fn.(manifest_path),
         true <- Enum.any?(manifest.triggers, &match?(%{type: :startup}, &1)),
         true <- registry_fn.(agent_name) do
      Logger.info("TriggerArming: firing startup trigger for agent #{inspect(agent_name)}")
      start_run_fn.(trigger: "startup", agent: agent_name)
      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Milliseconds from `now_dt` until the next daily occurrence of `time` (minute
  precision). Strictly positive: a window that is exactly now or already past
  schedules for tomorrow — this is the no-catch-up guarantee.
  """
  @spec ms_until_next_time(DateTime.t(), Time.t()) :: pos_integer()
  def ms_until_next_time(now_dt, %Time{} = time) do
    {:ok, today_target} = DateTime.new(DateTime.to_date(now_dt), time, now_dt.time_zone)

    target_dt =
      case DateTime.compare(now_dt, today_target) do
        :lt ->
          today_target

        _ ->
          # Today's window is now or past — next occurrence is tomorrow.
          tomorrow = Date.add(DateTime.to_date(now_dt), 1)
          {:ok, tomorrow_target} = DateTime.new(tomorrow, time, now_dt.time_zone)
          tomorrow_target
      end

    DateTime.diff(target_dt, now_dt, :millisecond)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    state = %{
      list_active_fn:
        Keyword.get(opts, :list_active_fn, &AgentOS.DeploymentRegistry.list_active/0),
      registry_fn:
        Keyword.get(opts, :registry_fn, &AgentOS.DeploymentRegistry.deployed_and_active?/1),
      manifest_load_fn: Keyword.get(opts, :manifest_load_fn, &AgentOS.Manifest.load/1),
      start_run_fn: Keyword.get(opts, :start_run_fn, &AgentOS.RunSupervisor.start_run/1),
      schedule_fn:
        Keyword.get(opts, :schedule_fn, fn message, ms ->
          Process.send_after(self(), message, ms)
        end),
      cancel_fn: Keyword.get(opts, :cancel_fn, &Process.cancel_timer/1),
      get_record_fn: Keyword.get(opts, :get_record_fn, &AgentOS.DeploymentRegistry.get/1),
      now_fn: Keyword.get(opts, :now_fn, &DateTime.utc_now/0),
      # agent_name => %{at => timer_ref}, kept so timers can be cancelled and re-armed.
      armed: %{}
    }

    {:ok, arm_all(state)}
  end

  @impl true
  def handle_call({:disarm, agent_name}, _from, state) do
    {:reply, :ok, disarm_agent(state, agent_name)}
  end

  @impl true
  def handle_call({:rearm, agent_name}, _from, state) do
    # Cancel whatever is armed, then arm the CURRENT manifest triggers so a schedule edit
    # or a resume takes effect without a reboot.
    disarmed = disarm_agent(state, agent_name)
    {:reply, :ok, rearm_agent(disarmed, agent_name)}
  end

  @impl true
  def handle_info({:fire, agent_name, at}, state) do
    # Re-check the registry at fire time — a deployment revoked after arming
    # (or marked inactive at boot) must never run.
    if state.registry_fn.(agent_name) do
      Logger.info("TriggerArming: firing time trigger #{at} for agent #{inspect(agent_name)}")
      state.start_run_fn.(trigger: "time:" <> at, agent: agent_name)
    else
      Logger.warning(
        "TriggerArming: skipping time trigger #{at} for agent #{inspect(agent_name)} — " <>
          "no longer deployed/active"
      )
    end

    # Re-arm the next daily occurrence ONLY if this (agent, at) is still armed. A
    # `{:fire, …}` message already queued when a disarm/rearm cancelled its timer
    # (the classic cancel_timer race) must not resurrect a schedule we just tore down —
    # otherwise a deleted agent or an edited-away time would keep firing forever.
    if get_in(state.armed, [agent_name, at]) do
      {:noreply, arm_one(state, agent_name, at)}
    else
      Logger.info(
        "TriggerArming: dropping stale fire for #{inspect(agent_name)} at #{at} — no longer armed"
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_info(other, state) do
    Logger.warning("TriggerArming: unexpected message #{inspect(other)} — ignoring")
    {:noreply, state}
  end

  # --- Arming helpers ---

  # Reads every active registry record and arms its manifest-declared time triggers.
  defp arm_all(state) do
    Enum.reduce(state.list_active_fn.(), state, fn record, acc ->
      case state.manifest_load_fn.(record.manifest_path) do
        {:ok, manifest} ->
          # Fire any startup trigger once for this boot (gated by the registry),
          # reusing this module's injected deps so boot stays hermetic in tests.
          fire_startup(record.agent_name, record.manifest_path,
            registry_fn: state.registry_fn,
            manifest_load_fn: state.manifest_load_fn,
            start_run_fn: state.start_run_fn
          )

          manifest.triggers
          |> Enum.filter(&match?(%{type: :time}, &1))
          |> Enum.reduce(acc, fn %{at: at}, inner -> arm_one(inner, record.agent_name, at) end)

        {:error, reason} ->
          # Loud failure + inactive, never a boot crash (Constitution VI).
          Logger.error(
            "TriggerArming: manifest missing/unloadable for deployed agent " <>
              "#{inspect(record.agent_name)} at #{inspect(record.manifest_path)}: " <>
              "#{inspect(reason)} — marking inactive"
          )

          :ok = AgentOS.DeploymentRegistry.mark_inactive(record.agent_name)
          acc
      end
    end)
  end

  # Schedules the next daily occurrence of one agent's "HH:MM" trigger, keeping the timer
  # ref so it can be cancelled on disarm/rearm.
  defp arm_one(state, agent_name, at) do
    case parse_time(at) do
      {:ok, time} ->
        ms = ms_until_next_time(state.now_fn.(), time)
        ref = state.schedule_fn.({:fire, agent_name, at}, ms)
        agent_timers = state.armed |> Map.get(agent_name, %{}) |> Map.put(at, ref)
        %{state | armed: Map.put(state.armed, agent_name, agent_timers)}

      :error ->
        Logger.error(
          "TriggerArming: invalid time trigger #{inspect(at)} for agent " <>
            "#{inspect(agent_name)} — not armed"
        )

        state
    end
  end

  # Arms the agent's CURRENT manifest time triggers — only if its record exists and is active.
  # A paused/deleted agent (no record or inactive) is left with nothing armed.
  defp rearm_agent(state, agent_name) do
    with %{active: true, manifest_path: manifest_path} <- state.get_record_fn.(agent_name),
         {:ok, manifest} <- state.manifest_load_fn.(manifest_path) do
      manifest.triggers
      |> Enum.filter(&match?(%{type: :time}, &1))
      |> Enum.reduce(state, fn %{at: at}, acc -> arm_one(acc, agent_name, at) end)
    else
      {:error, reason} ->
        Logger.error(
          "TriggerArming: rearm could not load manifest for #{inspect(agent_name)}: " <>
            "#{inspect(reason)} — left disarmed"
        )

        state

      _ ->
        # No record or inactive: nothing to arm (paused/deleted agent).
        state
    end
  end

  # Cancels every armed timer for one agent and forgets it. Also flushes any already-queued
  # `{:fire, …}` message for a cancelled timer so it cannot trigger a duplicate run — the
  # handle_info guard covers late-delivered stale fires, this covers ones already in the box.
  defp disarm_agent(state, agent_name) do
    case Map.get(state.armed, agent_name) do
      nil ->
        state

      timers ->
        Enum.each(timers, fn {at, ref} -> cancel_and_flush(state, agent_name, at, ref) end)
        %{state | armed: Map.delete(state.armed, agent_name)}
    end
  end

  # Cancels one timer and drains its stale fire message if it already landed in the mailbox.
  defp cancel_and_flush(state, agent_name, at, ref) do
    state.cancel_fn.(ref)

    receive do
      {:fire, ^agent_name, ^at} -> :ok
    after
      0 -> :ok
    end
  end

  # Parses "HH:MM" into a Time, tolerating single-digit hours.
  defp parse_time(at) when is_binary(at) do
    case String.split(at, ":") do
      [h, m] ->
        with {hour, ""} <- Integer.parse(h),
             {minute, ""} <- Integer.parse(m),
             true <- hour in 0..23 and minute in 0..59 do
          {:ok, Time.new!(hour, minute, 0)}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_time(_), do: :error
end
