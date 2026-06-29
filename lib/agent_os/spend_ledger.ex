defmodule AgentOS.SpendLedger do
  @moduledoc """
  Pure helper module for calculating spend ledger window limits and rollover conditions.
  No processes or side effects are performed here.
  """

  @type entry :: %{spent: number(), window_start: DateTime.t()}
  @type window :: :daily

  @doc """
  Returns the duration of the given window type in seconds.
  """
  @spec duration_seconds(window()) :: pos_integer()
  def duration_seconds(:daily), do: 86_400

  @doc """
  Determines if the current time `now` has reached or passed the window boundary
  anchored at `window_start`.
  """
  @spec rolled_over?(DateTime.t(), DateTime.t(), window()) :: boolean()
  def rolled_over?(window_start, now, window) do
    duration = duration_seconds(window)
    boundary = DateTime.add(window_start, duration, :second)
    DateTime.compare(now, boundary) != :lt
  end

  @doc """
  Returns the normalized/current entry. If the window has rolled over, resets
  the spend to 0 and anchors the window at `now`. Otherwise returns the entry unchanged.
  """
  @spec current_entry(entry(), DateTime.t(), window()) :: entry()
  def current_entry(entry, now, window) do
    if rolled_over?(entry.window_start, now, window) do
      %{spent: 0, window_start: now}
    else
      entry
    end
  end
end
