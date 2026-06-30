defmodule AgentOS.ConformanceAuditor.Scheduler do
  @moduledoc """
  A self-rescheduling GenServer that triggers daily conformance audits.
  """

  use GenServer

  @default_run_hour 8

  @doc """
  Starts the ConformanceAuditor.Scheduler GenServer.
  Options:
    - `:run_fn` - The function to invoke on fire (defaults to `&AgentOS.ConformanceAuditor.run_pass/0`).
    - `:run_hour` - The UTC hour to trigger the audit daily (defaults to configured hour or 8).
    - `:tz` - Timezone string, only "Etc/UTC" is supported at v0 (defaults to "Etc/UTC").
    - `:name` - Process name registration (defaults to `__MODULE__`).
  """
  def start_link(opts \\ []) do
    {name, opts_without_name} = Keyword.pop(opts, :name, __MODULE__)

    GenServer.start_link(
      __MODULE__,
      opts_without_name,
      [name: name] |> Enum.reject(fn {_, v} -> is_nil(v) end)
    )
  end

  @doc """
  A pure helper to compute the milliseconds from `now_dt` until the next daily
  occurrence of `hour` (0-23).
  """
  @spec ms_until_next(DateTime.t(), integer()) :: pos_integer()
  def ms_until_next(now_dt, hour) when is_integer(hour) and hour >= 0 and hour < 24 do
    time = Time.new!(hour, 0, 0)
    {:ok, today_target} = DateTime.new(DateTime.to_date(now_dt), time, now_dt.time_zone)

    target_dt =
      case DateTime.compare(now_dt, today_target) do
        :lt ->
          today_target

        _ ->
          tomorrow_date = Date.add(DateTime.to_date(now_dt), 1)
          {:ok, tomorrow_target} = DateTime.new(tomorrow_date, time, now_dt.time_zone)
          tomorrow_target
      end

    DateTime.diff(target_dt, now_dt, :millisecond)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    # Load configuration parameters.
    run_hour =
      Keyword.get(opts, :run_hour) ||
        Application.get_env(:agent_os, :audit_run_hour, @default_run_hour)

    tz = Keyword.get(opts, :tz, "Etc/UTC")
    run_fn = Keyword.get(opts, :run_fn, fn -> AgentOS.ConformanceAuditor.run_pass() end)

    state = %{
      run_hour: run_hour,
      tz: tz,
      run_fn: run_fn,
      timer_ref: nil,
      next_ms: nil
    }

    {:ok, schedule_next(state)}
  end

  @impl true
  def handle_info(:fire, state) do
    state.run_fn.()
    new_state = schedule_next(state)
    {:noreply, new_state}
  end

  # --- Private Helpers ---

  defp schedule_next(state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    now = DateTime.utc_now()
    ms = ms_until_next(now, state.run_hour)
    ref = Process.send_after(self(), :fire, ms)

    %{state | timer_ref: ref, next_ms: ms}
  end
end
