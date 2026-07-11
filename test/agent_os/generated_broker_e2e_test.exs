defmodule AgentOS.GeneratedBrokerE2ETest do
  # Feature 045 proof (SC-002 / US1-AC1): a generated agent CONTAINER reaches the inference
  # broker socket on the SHARED VOLUME and receives a completion — no ECONNREFUSED. This is
  # only meaningful with the substrate running in the OrbStack VM (AOS_IN_CONTAINER set), where
  # the broker's per-test socket lives on aos_inf:/run/aos and is mounted into the agent
  # container at the identical path. On the host (macOS) the cross-kernel connect cannot work —
  # that is the bug this feature fixes — so the test guards and notes a skip there.
  #
  # No live model (Constitution IV): the broker uses a STUBBED provider_fn.
  use ExUnit.Case, async: false

  alias AgentOS.RunWorker

  @tag :docker
  test "a dispatched generated agent connects to the shared-volume broker socket and gets a completion" do
    if System.get_env("AOS_IN_CONTAINER") in [nil, ""] do
      IO.puts(
        "[skip] GeneratedBrokerE2ETest requires the containerized substrate (AOS_IN_CONTAINER). " <>
          "Run via: docker compose run --rm substrate mix test --include docker"
      )

      :ok
    else
      rand = System.unique_integer([:positive])
      agent_name = "gen_broker_#{rand}"
      log_path = Path.join(System.tmp_dir!(), "gen_broker_#{rand}.md")
      manifest_path = Path.join(System.tmp_dir!(), "#{agent_name}.md")

      File.write!(manifest_path, """
      ---
      purpose: "Generated broker E2E manifest"
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

      # Stubbed provider — proves the round-trip without any live model call.
      completion = "e2e-inference-ok-#{rand}"

      _sock =
        AgentOS.TestHelper.start_broker_uds!(fn _model, _messages, _secret ->
          %{input_tokens: 5, output_tokens: 3, completion: completion}
        end)

      AgentOS.TestHelper.start_mounts!()

      # Generated body: connect to INFERENCE_SOCKET, POST /v1/inference, echo the completion.
      # A failed connect (ECONNREFUSED) raises → non-zero exit → RunWorker error, so a green
      # run proves the cross-container socket reached the broker (US1-AC1).
      code_dir = Path.expand(Path.join(["agents", agent_name]))
      File.mkdir_p!(code_dir)

      File.write!(Path.join(code_dir, "main.py"), """
      import os, sys, json, socket

      _ = sys.stdin.readline()
      run_token = os.environ["RUN_TOKEN"]
      sock_path = os.environ["INFERENCE_SOCKET"]

      s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
      s.connect(sock_path)
      body = json.dumps({"run_token": run_token, "model": os.environ.get("AGENT_MODEL", ""), "messages": [{"role": "user", "content": "ping"}]})
      req = ("POST /v1/inference HTTP/1.1\\r\\nHost: localhost\\r\\nContent-Type: application/json\\r\\n"
             "Content-Length: %d\\r\\nConnection: close\\r\\n\\r\\n%s" % (len(body), body))
      s.sendall(req.encode())
      data = b""
      while True:
          chunk = s.recv(4096)
          if not chunk:
              break
          data += chunk
      s.close()
      resp_body = data.decode().split("\\r\\n\\r\\n", 1)[1]
      comp = json.loads(resp_body).get("completion")
      print(json.dumps({"outcome": "completed", "reason": comp}))
      """)

      on_exit(fn ->
        File.rm_rf(code_dir)
        File.rm(log_path)
        File.rm(manifest_path)
      end)

      assert :ok =
               RunWorker.run_once(
                 agent: agent_name,
                 manifest_path: manifest_path,
                 run_log_path: log_path,
                 run_token: "gen_broker_run_#{rand}"
               )

      log = File.read!(log_path)
      assert log =~ "status=ok"
      refute log =~ "ECONNREFUSED"
    end
  end
end
