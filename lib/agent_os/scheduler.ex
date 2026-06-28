defmodule AgentOS.Scheduler do
  @moduledoc """
  A self-rescheduling GenServer that implements daily triggers (REQ-trigger-time).
  It calculates milliseconds until the next scheduled time and schedules a fire
  event using `Process.send_after/3`.
  """

  use GenServer

  # Default run hour is 07:00
  @default_run_hour 7

  @doc """
  Starts the Scheduler GenServer.
  Options:
    - `:run_fn` - The function to invoke on fire (defaults to `&AgentOS.Provisioner.fire_run/0`).
    - `:run_hour` - The UTC hour to trigger the agent daily (defaults to configured hour or 7).
    - `:tz` - Timezone string, only "Etc/UTC" is supported at v0 (defaults to configured tz or "Etc/UTC").
    - `:name` - Optional process name registration (defaults to `__MODULE__`).
  """
  def start_link(opts \\ []) do
    # Keyword.pop/3 extracts the value of :name from the options list and returns
    # a 2-tuple containing the name and the remaining options without :name.
    {name, opts_without_name} = Keyword.pop(opts, :name, __MODULE__)

    # We pass the cleaned options list to GenServer.start_link.
    # [name: name] |> Enum.reject/2 ensures that if `name` is nil, we don't pass name registration.
    GenServer.start_link(
      __MODULE__,
      opts_without_name,
      [name: name] |> Enum.reject(fn {_, v} -> is_nil(v) end)
    )
  end

  @doc """
  Triggers a manual run immediately. Passes `trigger: :manual` to the supervisor.
  """
  @spec run_now(atom(), keyword()) :: :ok
  def run_now(:manual, opts \\ []) do
    merged_opts = Keyword.put(opts, :trigger, :manual)
    AgentOS.RunSupervisor.start_run(merged_opts)
    :ok
  end

  @doc """
  A pure helper to compute the milliseconds from `now_dt` until the next daily
  occurrence of `hour` (0-23).
  Guaranteed to return a strictly positive integer (> 0). If today's scheduled hour
  has already passed or is equal to `now_dt`, it calculates for tomorrow's occurrence.
  """
  @spec ms_until_next(DateTime.t(), integer()) :: pos_integer()
  def ms_until_next(now_dt, hour) when is_integer(hour) and hour >= 0 and hour < 24 do
    # Time.new!/3 creates a Time struct, raising an exception if values are invalid.
    time = Time.new!(hour, 0, 0)

    # Construct a DateTime representing today's occurrence.
    # DateTime.to_date/1 extracts the Date struct from the given DateTime.
    {:ok, today_target} = DateTime.new(DateTime.to_date(now_dt), time, now_dt.time_zone)

    # Compare the current time with today's target time.
    target_dt =
      case DateTime.compare(now_dt, today_target) do
        # If current time is strictly less than today's target time, target today.
        :lt ->
          today_target

        # If today's target time has already passed or is equal to current time:
        _ ->
          # Add 1 day to the current date.
          tomorrow_date = Date.add(DateTime.to_date(now_dt), 1)
          # Construct a DateTime representing tomorrow's occurrence.
          {:ok, tomorrow_target} = DateTime.new(tomorrow_date, time, now_dt.time_zone)
          tomorrow_target
      end

    # Return the time difference in milliseconds between target_dt and now_dt.
    DateTime.diff(target_dt, now_dt, :millisecond)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    # Load configuration parameters.
    # Fallback to defaults using try-rescue block if Provisioner is not ready.
    agent_config =
      try do
        AgentOS.Provisioner.agent_config()
      rescue
        _ -> %{run_hour: @default_run_hour, tz: "Etc/UTC"}
      end

    # Prioritize values from options (opts), fallback to application config, then fallback to defaults.
    run_hour = Keyword.get(opts, :run_hour, Map.get(agent_config, :run_hour, @default_run_hour))
    tz = Keyword.get(opts, :tz, Map.get(agent_config, :tz, "Etc/UTC"))
    run_fn = Keyword.get(opts, :run_fn, &AgentOS.Provisioner.fire_run/0)

    # Build the initial state map.
    state = %{
      run_hour: run_hour,
      tz: tz,
      run_fn: run_fn,
      timer_ref: nil,
      next_ms: nil
    }

    # Arm the first timer by calling schedule_next/1, and return {:ok, state}.
    {:ok, schedule_next(state)}
  end

  @impl true
  def handle_info(:fire, state) do
    # Execute the configured run function.
    # In Elixir, `state.run_fn.()` calls the anonymous function bound to run_fn.
    state.run_fn.()

    # Re-arm the timer for the next daily occurrence.
    new_state = schedule_next(state)

    # Return {:noreply, new_state} to update the GenServer's state.
    {:noreply, new_state}
  end

  # --- Private Helpers ---

  # Helper function to compute the duration, schedule the message, and store the timer reference.
  defp schedule_next(state) do
    # If an existing timer reference exists, cancel it first to prevent leaking timers.
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    # Get current UTC time.
    now = DateTime.utc_now()

    # Calculate milliseconds until the next scheduled hour.
    ms = ms_until_next(now, state.run_hour)

    # Schedule the atom `:fire` to be sent to self (`self()`) after `ms` milliseconds.
    # Returns a reference that can be used to cancel the timer.
    ref = Process.send_after(self(), :fire, ms)

    # Return the updated state map.
    # `%{map | key: value}` is the syntax for updating existing keys in Elixir maps.
    %{state | timer_ref: ref, next_ms: ms}
  end
end
