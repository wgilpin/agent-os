defmodule AgentOS.ConformanceAuditor.AlertTest do
  use ExUnit.Case, async: true

  alias AgentOS.ConformanceAuditor.Alert
  alias AgentOS.ConformanceAuditor.Flag
  import ExUnit.CaptureLog

  setup do
    tmp_alert_path =
      Path.join(System.tmp_dir!(), "admin_alerts_#{System.unique_integer([:positive])}.md")

    tmp_run_log_path =
      Path.join(System.tmp_dir!(), "run_log_#{System.unique_integer([:positive])}.md")

    on_exit(fn ->
      File.rm(tmp_alert_path)
      File.rm(tmp_run_log_path)
    end)

    {:ok, tmp_alert_path: tmp_alert_path, tmp_run_log_path: tmp_run_log_path}
  end

  test "emit/3 appends one formatted line to admin_alerts_path, logs warning, and does not touch run_log",
       %{
         tmp_alert_path: alert_path,
         tmp_run_log_path: run_log_path
       } do
    flag = %Flag{
      type: :quiet,
      severity: :health,
      description: "No action in 3 consecutive runs"
    }

    log =
      capture_log(fn ->
        assert :ok ==
                 Alert.emit("discovery", flag, path: alert_path, now: ~U[2026-06-30 10:00:00Z])
      end)

    # Check that a log message was printed
    assert log =~ "conformance alert raised"
    assert log =~ "agent=discovery"
    assert log =~ "flag=quiet"

    # Check that the alert file contains exactly the expected line
    assert File.exists?(alert_path)
    content = File.read!(alert_path)

    assert content ==
             "- [2026-06-30T10:00:00Z] agent=discovery flag=quiet severity=health No action in 3 consecutive runs\n"

    # Check that the run log was not created/touched
    refute File.exists?(run_log_path)
  end
end
