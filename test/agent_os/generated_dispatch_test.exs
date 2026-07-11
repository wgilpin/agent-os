defmodule AgentOS.GeneratedDispatchTest do
  # Exercises production dispatch of a generated agent through RunWorker: the payload it
  # receives, the loud pre-flight failures, the retained override, and the end-to-end
  # jailed run. Not async — touches shared mounts and (for @tag :docker) the daemon.
  use ExUnit.Case, async: false

  alias AgentOS.RunWorker

  setup do
    rand = System.unique_integer([:positive])
    tmp_log = Path.join(System.tmp_dir!(), "generated_dispatch_#{rand}.md")

    AgentOS.TestHelper.start_mounts!()
    start_supervised!(AgentOS.InferenceBroker)

    # A generated agent (name ≠ the config/discovery agent) with a minimal manifest.
    agent_name = "gen_agent_#{rand}"
    manifest_path = Path.join(System.tmp_dir!(), "#{agent_name}.md")

    File.write!(manifest_path, """
    ---
    purpose: "Generated dispatch test manifest"
    owner: human
    supervision: restart-once-and-alert
    grants:
      - connector: kv_append
        methods: ["append"]
    spend:
      cap: 500000
      window: daily
      on_breach: kill
    ---
    """)

    on_exit(fn ->
      File.rm(tmp_log)
      File.rm(manifest_path)
    end)

    {:ok,
     log_path: tmp_log,
     manifest_path: manifest_path,
     agent_name: agent_name,
     run_token: "gen_run_token_#{rand}"}
  end

  defp outcome_json, do: Jason.encode!(%{"outcome" => "completed", "reason" => "ok"})

  # --- US1: payload discriminator (no Docker) ---

  describe "US1 — generated payload shape" do
    test "generated agent receives {roster}+trigger_input, never bookmarks/full payload", ctx do
      # Capture what crosses the boundary using a stdin-capturing override command.
      capture = Path.join(System.tmp_dir!(), "payload_#{System.unique_integer([:positive])}.json")
      script = Path.join(System.tmp_dir!(), "capture_#{System.unique_integer([:positive])}.sh")
      # `head -n 1` grabs exactly the one payload line (and closes stdin so it doesn't block),
      # then we emit a terminal outcome record with a trailing newline like the echo stubs do.
      File.write!(
        script,
        "#!/bin/sh\nhead -n 1 > #{capture}\nprintf '%s\\n' '#{outcome_json()}'\n"
      )

      File.chmod!(script, 0o755)
      on_exit(fn -> File.rm(script) && File.rm(capture) end)

      assert :ok =
               RunWorker.run_once(
                 agent: ctx.agent_name,
                 manifest_path: ctx.manifest_path,
                 agent_cmd: "sh",
                 agent_args: [script],
                 trigger_input: %{"msg" => "hello"},
                 run_log_path: ctx.log_path,
                 run_token: ctx.run_token
               )

      payload = capture |> File.read!() |> Jason.decode!()
      assert Map.has_key?(payload, "roster")
      assert payload["trigger_input"] == %{"msg" => "hello"}
      # The config agent's bookmark input must NOT leak to a generated agent.
      refute Map.has_key?(payload, "items")
      refute Map.has_key?(payload, "state")
    end
  end

  # --- US3: override retained (no Docker) ---

  describe "US3 — explicit override honoured (FR-006)" do
    test "an explicit non-docker agent_cmd dispatches as directed", ctx do
      assert :ok =
               RunWorker.run_once(
                 agent: ctx.agent_name,
                 manifest_path: ctx.manifest_path,
                 agent_cmd: "echo",
                 agent_args: [outcome_json()],
                 run_log_path: ctx.log_path,
                 run_token: ctx.run_token
               )

      assert File.read!(ctx.log_path) =~ "status=ok"
    end
  end

  # --- US1/FR-009: loud failures ---

  describe "loud dispatch failures (FR-009 / SC-005)" do
    test "missing agent code directory fails as code_unmountable, no host fallback (no docker)",
         ctx do
      # No override → sandbox path. The generated agent's agents/<name>/ does not exist, so
      # the pre-flight fails on the code-mount check BEFORE any docker call.
      assert {:error, :code_unmountable} =
               RunWorker.run_once(
                 agent: ctx.agent_name,
                 manifest_path: ctx.manifest_path,
                 run_log_path: ctx.log_path,
                 run_token: ctx.run_token
               )

      assert File.read!(ctx.log_path) =~ "failure_cause=code_unmountable"
    end

    @tag :docker
    test "unknown runtime image fails as image_unavailable, no host fallback", ctx do
      # Point at a real (existing) code dir so the pre-flight advances to the image check,
      # then supply a bogus image so `docker image inspect` fails as image-missing.
      assert {:error, :image_unavailable} =
               RunWorker.run_once(
                 agent: "discovery",
                 manifest_path: "test/fixtures/manifests/discovery.md",
                 image: "agent-nonexistent:doesnotexist",
                 run_log_path: ctx.log_path,
                 run_token: ctx.run_token
               )

      assert File.read!(ctx.log_path) =~ "failure_cause=image_unavailable"
    end
  end

  # --- US1: end-to-end jailed run ---

  describe "US1 — generated agent runs jailed end-to-end" do
    @tag :docker
    test "a generated body runs inside the container via the generated image + ro mount", ctx do
      # A benign generated body placed at agents/<name>/ so dispatch_spec mounts it read-only.
      # It reads the payload line and prints a terminal outcome record — proving a mounted
      # generated body EXECUTES inside the container (agent-generated:dev, network none,
      # read-only root, non-root) and produces its normal output (US1-AC1/AC3, SC-003).
      # (The inference UDS from inside the container is the identical mount + env the config
      # agent's isolation suite already proves; a generated body reaches it the same way.)
      code_dir = Path.expand(Path.join(["agents", ctx.agent_name]))
      File.mkdir_p!(code_dir)

      File.write!(Path.join(code_dir, "main.py"), """
      import sys, json
      _ = sys.stdin.readline()
      print(json.dumps({"outcome": "completed", "reason": "jailed run ok"}))
      """)

      on_exit(fn -> File.rm_rf(code_dir) end)

      assert :ok =
               RunWorker.run_once(
                 agent: ctx.agent_name,
                 manifest_path: ctx.manifest_path,
                 run_log_path: ctx.log_path,
                 run_token: ctx.run_token
               )

      assert File.read!(ctx.log_path) =~ "status=ok"
    end
  end
end
