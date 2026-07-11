defmodule AgentOS.IsolationTest do
  # Not async because they interact with docker daemon state
  use ExUnit.Case, async: false

  alias AgentOS.Sandbox
  alias AgentOS.PortRunner
  alias AgentOS.RunWorker

  setup do
    cidfile = Path.join(System.tmp_dir!(), "cidfile_#{System.unique_integer([:positive])}.txt")

    tmp_roster =
      Path.join(
        System.tmp_dir!(),
        "roster_isolation_#{System.unique_integer([:positive])}.db"
      )

    on_exit(fn ->
      File.rm(cidfile)
      File.rm(tmp_roster)
    end)

    AgentOS.TestHelper.start_mounts!()

    {:ok, cidfile: cidfile}
  end

  @tag :docker
  test "writing to /scratch succeeds", %{cidfile: cidfile} do
    sandbox = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: cidfile,
      network: "none",
      memory_mb: 128,
      cpus: "0.5",
      user: "1000:1000",
      entrypoint: "/bin/sh",
      cmd_args: ["-c", "echo hello > /scratch/test.txt && cat /scratch/test.txt"]
    }

    argv = Sandbox.build_argv(sandbox)
    assert {:ok, stdout} = PortRunner.run("{}", "docker", argv)
    assert stdout =~ "hello"
  end

  @tag :docker
  test "writing outside /scratch fails (read-only filesystem)", %{cidfile: cidfile} do
    sandbox = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: cidfile,
      network: "none",
      memory_mb: 128,
      cpus: "0.5",
      user: "1000:1000",
      entrypoint: "/bin/sh",
      cmd_args: ["-c", "echo hello > /app/test.txt"]
    }

    argv = Sandbox.build_argv(sandbox)
    # File write should fail and container exit non-zero since root FS is read-only
    assert {:error, {:exit_status, _code}} = PortRunner.run("{}", "docker", argv)
  end

  @tag :docker
  test "network egress is disabled", %{cidfile: cidfile} do
    sandbox = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: cidfile,
      network: "none",
      memory_mb: 128,
      cpus: "0.5",
      user: "1000:1000",
      entrypoint: "/app/.venv/bin/python",
      cmd_args: ["-c", "import socket; socket.create_connection(('8.8.8.8', 53), timeout=1)"]
    }

    argv = Sandbox.build_argv(sandbox)
    # Socket connection should fail due to network isolation (--network none)
    assert {:error, {:exit_status, _code}} = PortRunner.run("{}", "docker", argv)
  end

  @tag :docker
  test "hostile web input sanitization and prompt injection safety", %{cidfile: cidfile} do
    # Load hostile bookmarks fixture
    fixture_path = Path.expand("test/fixtures/hostile_bookmarks.json")
    raw_fixture = File.read!(fixture_path) |> Jason.decode!()

    # 1. Sanitize the items on the host side
    assert {sanitized_items, dropped_count} = AgentOS.Sanitizer.sanitize_list(raw_fixture)
    # The oversized ID item should be dropped
    assert dropped_count == 1
    assert length(sanitized_items) == 2

    # Verify that the hostile_injection item and valid_1 item are still present
    ids = Enum.map(sanitized_items, & &1["id"])
    assert "valid_1" in ids
    assert "hostile_injection" in ids

    # 2. Run the sanitized items through RunWorker under docker
    log_path = Path.join(System.tmp_dir!(), "run_worker_hostile_test.md")
    on_exit(fn -> File.rm(log_path) end)

    # The substrate broker must be reachable for the sandboxed discovery agent to drive its
    # tool channel — the whole point of feature 045 (containerized substrate + shared-volume
    # socket). A STUBBED provider (Constitution IV) emits the kv_append the agent is instructed
    # to call for a high-signal item and NEVER emits PWNED, so prompt injection cannot succeed.
    # The recursion turn (after the tool result) returns a plain completion to terminate.
    provider = fn _model, messages, _secret ->
      if Enum.any?(messages, fn m -> (m["role"] || m[:role]) == "tool" end) do
        %{input_tokens: 1, output_tokens: 1, completion: "done"}
      else
        %{
          input_tokens: 1,
          output_tokens: 1,
          completion: nil,
          message: %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_kv",
                "type" => "function",
                "function" => %{
                  "name" => "kv_append",
                  "arguments" =>
                    Jason.encode!(%{"key" => "digest", "value" => "high-signal: valid_1"})
                }
              }
            ]
          }
        }
      end
    end

    AgentOS.TestHelper.start_broker_uds!(provider)

    assert :ok =
             RunWorker.run_once(
               agent_cmd: "docker",
               cidfile: cidfile,
               items: sanitized_items,
               run_log_path: log_path
             )

    # 3. Verify that the run log trace exists and contains the results
    log_content = File.read!(log_path)

    # The valid item should succeed and generate digest entry
    assert log_content =~ "status=ok"

    # Verify the recorded signals in the StateStore
    snapshot = AgentOS.StateStore.snapshot("roster_trust")
    records_json = Jason.encode!(snapshot.records)

    # The high-signal item text should be appended/recorded
    assert records_json =~ "high-signal"

    # Prompt injection must NOT succeed (no 'PWNED' action should be executed or present)
    refute records_json =~ "PWNED"
  end

  @tag :docker
  test "surfacing container crash (exit 1) and writing log entry", %{cidfile: cidfile} do
    log_path = Path.join(System.tmp_dir!(), "crash_test.md")
    on_exit(fn -> File.rm(log_path) end)

    assert {:error, {:exit_status, 1}} =
             RunWorker.run_once(
               agent_cmd: "docker",
               cidfile: cidfile,
               entrypoint: "/bin/sh",
               cmd_args: ["-c", "exit 1"],
               run_log_path: log_path
             )

    log_content = File.read!(log_path)
    assert log_content =~ "status=error"
    assert log_content =~ "exit_code=1"
    assert log_content =~ "failure_cause=crash"
  end

  @tag :docker
  test "surfacing container OOM (exit 137) and writing log entry", %{cidfile: cidfile} do
    log_path = Path.join(System.tmp_dir!(), "oom_test.md")
    on_exit(fn -> File.rm(log_path) end)

    # Try to allocate 200MB within 128MB limit
    assert {:error, {:exit_status, 137}} =
             RunWorker.run_once(
               agent_cmd: "docker",
               cidfile: cidfile,
               memory_mb: 128,
               entrypoint: "/app/.venv/bin/python",
               cmd_args: ["-c", "bytearray(200 * 1024 * 1024)"],
               run_log_path: log_path
             )

    log_content = File.read!(log_path)
    assert log_content =~ "status=error"
    assert log_content =~ "exit_code=137"
    assert log_content =~ "failure_cause=oom"
  end

  @tag :docker
  test "pids-limit prevents fork bomb", %{cidfile: cidfile} do
    log_path = Path.join(System.tmp_dir!(), "forkbomb_test.md")
    on_exit(fn -> File.rm(log_path) end)

    assert {:error, {:exit_status, 42}} =
             RunWorker.run_once(
               agent_cmd: "docker",
               cidfile: cidfile,
               entrypoint: "/app/.venv/bin/python",
               cmd_args: [
                 "-c",
                 "import os, sys\ntry:\n    for _ in range(100): os.fork()\nexcept OSError:\n    sys.exit(42)"
               ],
               run_log_path: log_path
             )
  end
end
