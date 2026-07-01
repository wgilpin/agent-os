defmodule AgentOS.PortRunnerTest do
  use ExUnit.Case, async: false

  alias AgentOS.PortRunner

  @tag :integration
  test "happy path runs python discovery agent" do
    input = ~s({"roster": []})

    assert {:ok, output} =
             PortRunner.run(input, ".venv/bin/python", ["agents/discovery/main.py"], [])

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

  test "scrubs MODEL_KEY and OUTBOUND_TOKEN from spawned process environment" do
    # Set the credentials in the host process environment
    System.put_env("MODEL_KEY", "host_model_key_secret")
    System.put_env("OUTBOUND_TOKEN", "host_outbound_token_secret")

    # Run a command to echo the environment variables
    {:ok, output} =
      PortRunner.run(
        "",
        "bash",
        ["-c", "echo MODEL_KEY:=$MODEL_KEY,OUTBOUND_TOKEN:=$OUTBOUND_TOKEN"],
        []
      )

    # Clean them up in the host process
    System.delete_env("MODEL_KEY")
    System.delete_env("OUTBOUND_TOKEN")

    # Verify that they were not passed to the child process (should be empty)
    assert output =~ "MODEL_KEY:=,OUTBOUND_TOKEN:=\n"
  end
end
