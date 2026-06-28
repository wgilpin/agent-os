defmodule AgentOS.PortRunnerTest do
  use ExUnit.Case, async: true

  alias AgentOS.PortRunner

  @tag :integration
  test "happy path runs python discovery agent" do
    input = ~s({"roster": []})
    assert {:ok, output} = PortRunner.run(input, ".venv/bin/python", ["agents/discovery/main.py"], [])
    assert output =~ "actions"
  end

  test "bash echo hello" do
    assert {:ok, output} = PortRunner.run("", "bash", ["-c", "echo hello"], [])
    assert output =~ "hello"
  end

  test "returns exit status error on nonzero exit" do
    # Run a simple bash command that exits with code 1
    assert {:error, {:exit_status, 1}} = PortRunner.run("", "bash", ["-c", "exit 1"], [])
  end

  test "returns timeout error on slow execution" do
    # Run a bash command that sleeps for 2 seconds but set a 100ms timeout
    assert {:error, :timeout} = PortRunner.run("", "bash", ["-c", "sleep 2"], timeout_ms: 100)
  end
end
