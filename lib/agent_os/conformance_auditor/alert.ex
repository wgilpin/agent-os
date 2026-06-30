defmodule AgentOS.ConformanceAuditor.Alert do
  @moduledoc """
  Notification-only admin alert sink (Logger + admin_alerts.md).
  """

  require Logger
  alias AgentOS.ConformanceAuditor.Flag

  @default_path Path.join(["data", "admin_alerts.md"])

  @doc """
  Logs a warning and appends a line to the admin alerts log file.
  """
  @spec emit(String.t(), Flag.t(), keyword()) :: :ok
  def emit(agent, %Flag{} = flag, opts \\ []) do
    path =
      Keyword.get(opts, :path) ||
        Keyword.get(opts, :admin_alerts_path) ||
        Application.get_env(:agent_os, :admin_alerts_path, @default_path)

    now = Keyword.get(opts, :now) || DateTime.utc_now()
    timestamp = DateTime.to_iso8601(now)

    Logger.warning(
      "conformance alert raised: agent=#{agent} flag=#{flag.type} severity=#{flag.severity} description=#{flag.description}"
    )

    line =
      "- [#{timestamp}] agent=#{agent} flag=#{flag.type} severity=#{flag.severity} #{flag.description}\n"

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, line, [:append])

    :ok
  end
end
