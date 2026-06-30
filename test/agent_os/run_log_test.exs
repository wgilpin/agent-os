defmodule AgentOS.RunLogTest do
  use ExUnit.Case, async: true

  alias AgentOS.RunLog

  setup do
    tmp = Path.join(System.tmp_dir!(), "run_log_#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(tmp) end)
    {:ok, tmp: tmp}
  end

  test "append/2 writes a line to file with UTC timestamp", %{tmp: tmp} do
    assert :ok = RunLog.append(%{status: :ok, actions: 1, note: "ran"}, path: tmp)
    assert File.exists?(tmp)
    content = File.read!(tmp)
    assert content =~ "status=ok"
    assert content =~ "actions=1"
    assert content =~ "ran"
    assert content =~ "["
    assert content =~ "Z]"
  end

  test "append_digest/2 writes a digest line to file", %{tmp: tmp} do
    assert :ok = RunLog.append_digest("hello digest", path: tmp)
    assert File.exists?(tmp)
    content = File.read!(tmp)
    assert content =~ "digest: hello digest"
    assert content =~ "["
  end

  test "appends are append-only and ordered", %{tmp: tmp} do
    assert :ok = RunLog.append(%{status: :ok, actions: 1, note: "first"}, path: tmp)
    assert :ok = RunLog.append(%{status: :error, actions: 0, note: "second"}, path: tmp)

    lines = File.read!(tmp) |> String.split("\n", trim: true)
    assert length(lines) == 2
    assert Enum.at(lines, 0) =~ "first"
    assert Enum.at(lines, 1) =~ "second"
  end

  test "extended trigger provenance values round-trip append to parse", %{tmp: tmp} do
    for trigger <- ["event:bookmark_saved", "message", "approval-resume"] do
      try do
        File.rm(tmp)
      rescue
        _ -> :ok
      end

      assert :ok = RunLog.append(%{status: :ok, actions: 1, trigger: trigger}, path: tmp)
      content = File.read!(tmp)

      # Parse the trigger out using regex (similar to Inventory.parse_last_run)
      parsed_trigger =
        case Regex.run(~r/trigger=([^\s]+)/, content) do
          [_, val] -> val
          _ -> nil
        end

      assert parsed_trigger == trigger
    end
  end

  import ExUnit.CaptureLog

  test "read_records/2 parses records, excludes digest lines, and obeys window limit", %{tmp: tmp} do
    File.write!(tmp, """
    - [2026-06-30T10:00:00Z] digest: starting agent
    - [2026-06-30T10:01:00Z] status=ok actions=5 trigger=manual items_in=10 items_dropped=2 notes
    - [2026-06-30T10:02:00Z] digest: checkpoint saved
    - [2026-06-30T10:03:00Z] status=ok actions=0 trigger=timer quiet run
    - [2026-06-30T10:04:00Z] status=alert actions=1 trigger=approval-resume denied ref=ref_1 gate_reasons=["forbidden"] breached_count=1 note with info
    """)

    records = RunLog.read_records(tmp)
    assert length(records) == 3

    r1 = Enum.at(records, 0)
    assert r1.status == "ok"
    assert r1.actions == 5
    assert r1.trigger == "manual"
    assert r1.items_in == 10
    assert r1.items_dropped == 2
    assert r1.note == "notes"

    r2 = Enum.at(records, 1)
    assert r2.status == "ok"
    assert r2.actions == 0
    assert r2.trigger == "timer"
    assert r2.note == "quiet run"

    r3 = Enum.at(records, 2)
    assert r3.status == "alert"
    assert r3.actions == 1
    assert r3.trigger == "approval-resume"
    assert r3.breached_count == 1
    assert r3.gate_reasons == ["forbidden"]
    assert r3.note == "denied ref=ref_1 note with info"

    limited_records = RunLog.read_records(tmp, window: 2)
    assert length(limited_records) == 2
    assert Enum.at(limited_records, 0).note == "quiet run"
    assert Enum.at(limited_records, 1).note == "denied ref=ref_1 note with info"
  end

  test "read_records/2 skips malformed lines and logs a warning", %{tmp: tmp} do
    File.write!(tmp, """
    - [2026-06-30T10:01:00Z] status=ok actions=5 valid record
    - [2026-06-30T10:02:00Z] status=ok actions=invalid_number malformed record
    - [2026-06-30T10:03:00Z] status=ok actions=2 another valid record
    """)

    log =
      capture_log(fn ->
        records = RunLog.read_records(tmp)
        assert length(records) == 2
        assert Enum.at(records, 0).note == "valid record"
        assert Enum.at(records, 1).note == "another valid record"
      end)

    assert log =~ "Failed to parse run-log line"
    assert log =~ "actions=invalid_number"
  end
end
