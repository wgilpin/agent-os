defmodule AgentOS.RunWorkerDispatchTest do
  # Pure tests of the shared sandbox dispatch selection — no Docker, no broker/mounts.
  use ExUnit.Case, async: true

  alias AgentOS.RunWorker

  @uds Path.expand(Application.compile_env(:agent_os, :inference_uds_path, "data/inference.sock"))

  describe "dispatch_spec/3 — one shared path, differing only in image + mounts (US1)" do
    test "generated agent → generated image, read-only body mount, container interpreter" do
      spec = RunWorker.dispatch_spec("my_gen_agent", "discovery")

      assert spec.image == "agent-generated:dev"
      assert spec.entrypoint == "/app/.venv/bin/python"
      assert spec.cmd_args == ["/app/agents/my_gen_agent/main.py"]
      assert spec.code_dir == Path.expand("agents/my_gen_agent")

      # The body is mounted read-only, and the inference UDS is the ONLY non-":ro"
      # (writable host-backed) mount (FR-003/FR-007).
      assert {Path.expand("agents/my_gen_agent"), "/app/agents/my_gen_agent:ro"} in spec.mounts
      assert {@uds, "/tmp/inference.sock"} in spec.mounts

      writable = Enum.reject(spec.mounts, fn {_h, c} -> String.ends_with?(c, ":ro") end)
      assert writable == [{@uds, "/tmp/inference.sock"}]
    end

    test "config agent → config image, no code mount, baked entrypoint" do
      spec = RunWorker.dispatch_spec("discovery", "discovery")

      assert spec.image == "agent-discovery:dev"
      assert is_nil(spec.entrypoint)
      assert is_nil(spec.cmd_args)
      assert is_nil(spec.code_dir)
      assert spec.mounts == [{@uds, "/tmp/inference.sock"}]
    end

    test "explicit :image/:entrypoint/:cmd_args opts override (test/harness path)" do
      spec =
        RunWorker.dispatch_spec("g", "discovery",
          image: "x:y",
          entrypoint: "/bin/sh",
          cmd_args: ["-c", "true"]
        )

      assert spec.image == "x:y"
      assert spec.entrypoint == "/bin/sh"
      assert spec.cmd_args == ["-c", "true"]
    end

    # US3 / FR-005 — a generated agent never resolves to the host interpreter.
    test "generated dispatch never uses the host `.venv/bin/python`" do
      spec = RunWorker.dispatch_spec("g", "discovery")
      refute spec.entrypoint == ".venv/bin/python"
      assert String.starts_with?(spec.entrypoint, "/app/")
    end
  end

  describe "no-bypass structural guard (US3 / FR-005)" do
    test "run_worker source no longer injects a host-python command for generated agents" do
      src = File.read!("lib/agent_os/run_worker.ex")

      # The deleted bypass was the only place that branched on `agent_name != config_agent`
      # to inject `agent_cmd: python_bin()`. Its absence guards against reintroduction.
      # (python_bin/0 itself legitimately remains for the Provisioner rescue fallback.)
      refute src =~ "agent_name != config_agent"
    end
  end
end
