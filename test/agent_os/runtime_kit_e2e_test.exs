defmodule AgentOS.RuntimeKitE2ETest do
  # Feature 046 / US1+US2 (FR-011): the golden sample body (agents/sample_kit_agent)
  # runs across the PortRunner boundary against a real broker over the UDS, driving a
  # multi-step tool loop (search_notes -> add_todo -> final Result) entirely through the
  # kit — zero transport/env code in the body. No live model (Constitution IV): the
  # broker's provider_fn is a scripted stub. Spend reconciles call-for-call.
  use ExUnit.Case, async: false

  alias AgentOS.RunWorker
  alias AgentOS.StateStore

  @known_tools MapSet.new(["search_notes", "add_todo"])

  # Scripted OpenAI provider stub: mirrors the bake-off broker's conversation-state
  # script so the golden 3-step task threads correctly regardless of message framing.
  defp golden_provider do
    fn _model, messages, tools, _secret ->
      done = tools_done(messages)

      cond do
        not MapSet.member?(done, "search_notes") ->
          tool_usage("call_search", "search_notes", %{"query" => "quarterly report"})

        not MapSet.member?(done, "add_todo") ->
          tool_usage("call_todo", "add_todo", %{
            "title" => "Review quarterly report",
            "link" => "https://notes.local/q3"
          })

        true ->
          output_tool = find_output_tool(tools)

          tool_usage("call_final", output_tool, %{
            "outcome" => "done",
            "reason" => "searched notes and added the todo"
          })
      end
    end
  end

  # Returns the set of known tool names that already have a tool RESULT in history.
  defp tools_done(messages) do
    id_to_name =
      Enum.reduce(messages, %{}, fn m, acc ->
        Enum.reduce(Map.get(m, "tool_calls") || [], acc, fn tc, a ->
          Map.put(a, tc["id"], get_in(tc, ["function", "name"]))
        end)
      end)

    Enum.reduce(messages, MapSet.new(), fn m, acc ->
      if Map.get(m, "role") == "tool" do
        name = Map.get(m, "name") || Map.get(id_to_name, Map.get(m, "tool_call_id"))
        if name in @known_tools, do: MapSet.put(acc, name), else: acc
      else
        acc
      end
    end)
  end

  # The framework's registered output/result tool (pydantic-ai's "final_result").
  defp find_output_tool(tools) do
    Enum.find_value(tools || [], "final_result", fn t ->
      name = get_in(t, ["function", "name"])
      if name && name not in @known_tools, do: name, else: false
    end)
  end

  defp tool_usage(id, name, args) do
    %{
      input_tokens: 20,
      output_tokens: 10,
      completion: nil,
      message: %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => id,
            "type" => "function",
            "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
          }
        ]
      }
    }
  end

  defp python_kit_available? do
    python = Path.expand(".venv/bin/python")

    File.exists?(python) and
      match?(
        {_, 0},
        System.cmd(python, ["-c", "import pydantic_ai, agent_os_runtime"],
          env: [{"PYTHONPATH", File.cwd!()}],
          stderr_to_stdout: true
        )
      )
  end

  test "golden multi-step kit body completes over the port boundary and spend reconciles" do
    if not python_kit_available?() do
      IO.puts(
        "[skip] RuntimeKitE2ETest requires .venv/bin/python with pydantic_ai + agent_os_runtime importable."
      )

      :ok
    else
      rand = System.unique_integer([:positive])
      agent_name = "sample_kit_agent"
      log_path = Path.join(System.tmp_dir!(), "kit_e2e_#{rand}.md")
      # Manifest basename MUST equal the agent name (and the body dir agents/sample_kit_agent),
      # since run_worker derives the agent name and ledger key from it. Isolate per-run via a
      # unique parent dir rather than the filename.
      manifest_dir = Path.join(System.tmp_dir!(), "kit_e2e_manifest_#{rand}")
      File.mkdir_p!(manifest_dir)
      manifest_path = Path.join(manifest_dir, "#{agent_name}.md")

      File.write!(manifest_path, """
      ---
      purpose: "Runtime kit E2E golden task"
      owner: human
      supervision: restart-once-and-alert
      grants: []
      spend:
        cap: 100000
        window: daily
        on_breach: kill
      ---
      """)

      # Full store set (roster, spend ledger, transcript, deployments, ...) the run
      # pipeline reads/writes, then the real broker + UDS listener with the scripted
      # golden provider (no live model).
      AgentOS.TestHelper.start_mounts!()
      _sock = AgentOS.TestHelper.start_broker_uds!(golden_provider())

      # The body imports the repo-root kit; put repo root on PYTHONPATH for the child
      # (in-image this is baked as PYTHONPATH=/app). Restore afterwards.
      prev_pythonpath = System.get_env("PYTHONPATH")
      System.put_env("PYTHONPATH", File.cwd!())

      on_exit(fn ->
        if prev_pythonpath,
          do: System.put_env("PYTHONPATH", prev_pythonpath),
          else: System.delete_env("PYTHONPATH")

        File.rm(log_path)
        File.rm_rf(manifest_dir)
      end)

      # run_worker injects INFERENCE_SOCKET/RUN_TOKEN/AGENT_MODEL; the manifest_path's
      # basename must match the agent name so the body dir agents/sample_kit_agent is used.
      # We override the command to run the body directly via the venv interpreter (host
      # port-boundary run, no docker), exactly as the discovery E2E does.
      assert :ok =
               RunWorker.run_once(
                 manifest_path: manifest_path,
                 run_log_path: log_path,
                 run_token: "kit_e2e_run_#{rand}",
                 agent_cmd: ".venv/bin/python",
                 agent_args: ["agents/sample_kit_agent/main.py"],
                 timeout_ms: 60_000
               )

      # A green run means run_worker parsed a valid outcome record (outcome/reason present)
      # — the outcome-record contract held.
      log = File.read!(log_path)
      assert log =~ "status=ok"

      # Call-for-call spend reconciliation: exactly 3 metered model calls (search_notes,
      # add_todo, final_result), each 500 micro-dollars at the test prices => 1500.
      entry = StateStore.snapshot("spend_ledger") |> Map.get(agent_name)
      assert entry != nil, "expected a spend-ledger entry for #{agent_name}"
      assert entry.spent == 1500, "expected 3 metered calls (1500 µ$), got #{entry.spent}"
    end
  end
end
