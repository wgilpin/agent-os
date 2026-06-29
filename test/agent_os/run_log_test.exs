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
end
