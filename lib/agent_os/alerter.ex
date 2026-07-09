defmodule AgentOS.Alerter do
  @moduledoc """
  Fires warnings/logs and records alerts in the run log when supervision retries
  are exhausted (REQ-restart-policy).
  """

  require Logger

  @doc """
  Logs the retry exhaustion error and writes a persistent ALERT line in the run log.

  ## Parameters
    - `reason`: The error reason (e.g., `:persistent_failure`).
    - `opts`: Optional keyword list containing paths (e.g., `[run_log_path: "path"]`).
  """
  @spec alert(any(), keyword()) :: :ok
  def alert(reason, opts \\ []) do
    # Log the failure at error level. #{inspect(reason)} converts any Elixir term
    # to its textual representation for printing (like repr() in Python).
    Logger.error("restart-once exhausted: #{inspect(reason)}")

    # Extract log path from either :path or :run_log_path (used in tests/downstream calls).
    # Keyword.get/2 returns nil if the key is not found.
    path = Keyword.get(opts, :path) || Keyword.get(opts, :run_log_path)

    # If a path was explicitly provided, pass it in keyword list format [path: path],
    # otherwise default to empty list which lets RunLog.append default its path.
    append_opts = if path, do: [path: path], else: []

    # Write a status=alert entry to the persistent run-log file, attributed to the
    # dispatched agent when the run opts carried one.
    AgentOS.RunLog.append(
      %{status: :alert, actions: 0, agent: Keyword.get(opts, :agent), note: inspect(reason)},
      append_opts
    )

    # Return the atom :ok, confirming execution success.
    :ok
  end
end
