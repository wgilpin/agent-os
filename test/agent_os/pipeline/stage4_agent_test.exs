defmodule AgentOS.Pipeline.Stage4Test do
  use ExUnit.Case, async: false

  alias AgentOS.Pipeline.Stage4
  alias AgentOS.Pipeline.Stage4.AgentBody
  alias AgentOS.{InferenceBroker, StateStore, Manifest}
  alias AgentOS.Manifest.{Spend, Grant}

  @model "mock-codegen-model"
  @prices %{"mock-codegen-model" => %{input: 10_000_000, output: 30_000_000}}
  @now ~U[2026-06-30 12:00:00Z]

  setup do
    uniq = System.unique_integer([:positive])
    tmp = System.tmp_dir!()
    spend_path = Path.join(tmp, "spend_stage4_#{uniq}.db")
    spec_dir = Path.join(tmp, "stage4_agents_#{uniq}")

    on_exit(fn ->
      File.rm(spend_path)
      File.rm_rf(spec_dir)
    end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({StateStore, name: "spend_ledger", path: spend_path, initial: %{}})
    start_supervised!(AgentOS.CredentialProxy)
    start_supervised!(InferenceBroker)

    manifest = %Manifest{
      purpose: "Draft replies to recruiter emails; never auto-send.",
      owner: "human",
      supervision: "restart-once-and-alert",
      grants: [%Grant{connector: "gmail_draft", recipients: ["self"], methods: ["draft"]}],
      spend: %Spend{cap: 750_000, window: :daily, on_breach: :kill},
      mounts: [],
      triggers: []
    }

    token = "stage4_run_token"
    :ok = InferenceBroker.register(token, "recruiter_agent", manifest)

    base_opts = [
      run_token: token,
      model: @model,
      prices: @prices,
      now: @now,
      spec_dir: spec_dir
    ]

    {:ok, manifest: manifest, token: token, spec_dir: spec_dir, base_opts: base_opts}
  end

  # --- Fixture builders ------------------------------------------------------

  defp valid_main_py do
    """
    import sys
    import json
    from models import AgentInput

    def main():
        raw = sys.stdin.readline().strip()
        data = AgentInput.model_validate_json(raw)
        actions = [{"type": "kv_append", "payload": {"text": data.text}}]
        print(json.dumps({"actions": actions}))

    if __name__ == "__main__":
        main()
    """
  end

  defp valid_models_py do
    """
    from pydantic import BaseModel

    class AgentInput(BaseModel):
        text: str
    """
  end

  defp files_json(main_content \\ valid_main_py(), models_content \\ valid_models_py()) do
    Jason.encode!(%{
      "files" => [
        %{"path" => "main.py", "content" => main_content},
        %{"path" => "models.py", "content" => models_content}
      ]
    })
  end

  defp provider_returning(completion) do
    fn _model, _messages, _secret ->
      %{input_tokens: 5, output_tokens: 5, completion: completion}
    end
  end

  defp agent_files_path(spec_dir, agent_name, file) do
    Path.join([spec_dir, agent_name, file])
  end

  # --- US1: Synthesise a novel agent body from purpose + manifest -----------

  describe "US1: generate/3 core synthesis (T005-T012)" do
    test "writes main.py and models.py and returns a typed AgentBody", ctx do
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json()))

      assert {:ok, %AgentBody{agent_name: "recruiter_agent", files: files}} =
               Stage4.generate("recruiter_agent", ctx.manifest, opts)

      assert Enum.find(files, &(&1.path == "main.py"))
      assert Enum.find(files, &(&1.path == "models.py"))

      assert File.exists?(agent_files_path(ctx.spec_dir, "recruiter_agent", "main.py"))
      assert File.exists?(agent_files_path(ctx.spec_dir, "recruiter_agent", "models.py"))
    end

    test "purpose on the returned body is derived from the manifest", ctx do
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json()))

      {:ok, body} = Stage4.generate("recruiter_agent", ctx.manifest, opts)
      assert body.purpose == ctx.manifest.purpose
    end

    test "two distinct completions (standing in for two distinct purposes) yield materially different bodies",
         ctx do
      other_main = String.replace(valid_main_py(), "kv_append", "different_action_kind")

      opts_a = Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json()))

      opts_b =
        Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json(other_main)))

      {:ok, body_a} = Stage4.generate("recruiter_agent", ctx.manifest, opts_a)
      {:ok, body_b} = Stage4.generate("recruiter_agent", ctx.manifest, opts_b)

      main_a = Enum.find(body_a.files, &(&1.path == "main.py")).content
      main_b = Enum.find(body_b.files, &(&1.path == "main.py")).content

      refute main_a == main_b
    end

    test "rejects malformed synthesis output and writes nothing", ctx do
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_returning("not json"))

      assert {:error, :invalid_synthesis_output} =
               Stage4.generate("recruiter_agent", ctx.manifest, opts)

      refute File.exists?(agent_files_path(ctx.spec_dir, "recruiter_agent", "main.py"))
    end

    test "rejects an unsafe file path and writes nothing", ctx do
      bad_json =
        Jason.encode!(%{
          "files" => [
            %{"path" => "../evil.py", "content" => valid_main_py()},
            %{"path" => "models.py", "content" => valid_models_py()}
          ]
        })

      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_returning(bad_json))

      assert {:error, :unsafe_path} = Stage4.generate("recruiter_agent", ctx.manifest, opts)
      refute File.exists?(agent_files_path(ctx.spec_dir, "recruiter_agent", "models.py"))
    end

    test "rejects manifest with a granted connector missing tool_declaration (T010/T012)", ctx do
      # For example, gmail_read is currently mocked or missing a tool_declaration in tests
      manifest = %{
        ctx.manifest
        | grants: [
            %AgentOS.Manifest.Grant{
              connector: "missing_declaration",
              methods: nil,
              recipients: nil
            }
          ]
      }

      assert {:error, :missing_tool_declaration} =
               Stage4.generate("recruiter_agent", manifest, ctx.base_opts)
    end

    test "rejects synthesis output containing manifest literals (T012)", ctx do
      # Manifest grant literal "gmail_draft"
      leaking_main = String.replace(valid_main_py(), "kv_append", "gmail_draft")

      opts =
        Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json(leaking_main)))

      assert {:error, :manifest_leak_detected} =
               Stage4.generate("recruiter_agent", ctx.manifest, opts)
    end

    test "rejects a main.py missing the typed stdin/stdout contract and writes nothing", ctx do
      untyped_main = "print('hello world')\n"

      opts =
        Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json(untyped_main)))

      assert {:error, :missing_typed_contract} =
               Stage4.generate("recruiter_agent", ctx.manifest, opts)

      refute File.exists?(agent_files_path(ctx.spec_dir, "recruiter_agent", "main.py"))
    end

    test "rejects invalid Python syntax and writes nothing", ctx do
      broken_main = valid_main_py() <> "\ndef broken(:\n"
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json(broken_main)))

      assert {:error, :invalid_python_syntax} =
               Stage4.generate("recruiter_agent", ctx.manifest, opts)

      refute File.exists?(agent_files_path(ctx.spec_dir, "recruiter_agent", "main.py"))
    end
  end

  describe "US1: judge-blindness (T013-T014)" do
    test "synthesis prompt contains no free-text actions protocol (T012)", ctx do
      require AgentOS.InferenceBroker

      # Inspect the actual messages sent to the broker
      opts =
        Keyword.put(ctx.base_opts, :provider_fn, fn _model, messages, _secret ->
          system_prompt = Enum.map_join(messages, "\n", &(&1.content || ""))

          # The system prompt MUST NOT ask the model to produce free text {"actions": [...]}
          send(self(), {:system_prompt, system_prompt})

          %{input_tokens: 5, output_tokens: 5, completion: files_json()}
        end)

      assert {:ok, _} = Stage4.generate("recruiter_agent", ctx.manifest, opts)

      assert_received {:system_prompt, system_prompt}

      refute system_prompt =~ "free-text markdown block or JSON blob"
      refute system_prompt =~ "return its actions in a free-text"
      refute system_prompt =~ "\"actions\":"
    end

    test "synthesis prompt contains no hardcoded model identifier string (T026)", ctx do
      opts =
        Keyword.put(ctx.base_opts, :provider_fn, fn _model, messages, _secret ->
          system_prompt = Enum.map_join(messages, "\n", &(&1.content || ""))
          send(self(), {:system_prompt, system_prompt})
          %{input_tokens: 5, output_tokens: 5, completion: files_json()}
        end)

      assert {:ok, _} = Stage4.generate("recruiter_agent", ctx.manifest, opts)

      assert_received {:system_prompt, system_prompt}

      refute system_prompt =~ "google/gemini"
      refute system_prompt =~ "mock-model"
    end
  end

  # --- US2: Generated blind to the judge -------------------------------------

  describe "US2: judge-blindness (T013-T014)" do
    test "presence of judge_spec.json on disk does not change the synthesis result", ctx do
      judge_path = agent_files_path(ctx.spec_dir, "recruiter_agent", "judge_spec.json")
      File.mkdir_p!(Path.dirname(judge_path))

      File.write!(
        judge_path,
        Jason.encode!(%{
          "agent_name" => "recruiter_agent",
          "purpose" => "irrelevant",
          "tests" => []
        })
      )

      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json()))

      {:ok, with_judge_present} = Stage4.generate("recruiter_agent", ctx.manifest, opts)

      File.rm!(judge_path)

      {:ok, without_judge_present} = Stage4.generate("recruiter_agent", ctx.manifest, opts)

      assert with_judge_present.files == without_judge_present.files
    end
  end

  # --- US3: The body holds no manifest and no credential ---------------------

  describe "US3: no-manifest/credential-leak and no-direct-provider guards (T015-T019)" do
    test "rejects synthesis output embedding the manifest's spend cap literal", ctx do
      leaking_main = valid_main_py() <> "\n# cap is 750000\n"

      opts =
        Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json(leaking_main)))

      assert {:error, :manifest_leak_detected} =
               Stage4.generate("recruiter_agent", ctx.manifest, opts)

      refute File.exists?(agent_files_path(ctx.spec_dir, "recruiter_agent", "main.py"))
    end

    test "rejects synthesis output embedding a grant connector literal", ctx do
      leaking_main = valid_main_py() <> "\n# uses gmail_draft directly\n"

      opts =
        Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json(leaking_main)))

      assert {:error, :manifest_leak_detected} =
               Stage4.generate("recruiter_agent", ctx.manifest, opts)
    end

    test "rejects synthesis output containing a credential-shaped literal", ctx do
      leaking_main = valid_main_py() <> "\napi_key = \"sk-abcdefghijklmnop\"\n"

      opts =
        Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json(leaking_main)))

      assert {:error, :manifest_leak_detected} =
               Stage4.generate("recruiter_agent", ctx.manifest, opts)
    end

    test "rejects synthesis output referencing a direct provider SDK/host", ctx do
      leaking_main = String.replace(valid_main_py(), "import json", "import json\nimport openai")

      opts =
        Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json(leaking_main)))

      assert {:error, :direct_provider_path_detected} =
               Stage4.generate("recruiter_agent", ctx.manifest, opts)

      refute File.exists?(agent_files_path(ctx.spec_dir, "recruiter_agent", "main.py"))
    end

    test "rejects synthesis output performing direct (non-UDS) network I/O", ctx do
      leaking_main =
        String.replace(valid_main_py(), "import json", "import json\nimport requests")

      opts =
        Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json(leaking_main)))

      assert {:error, :direct_provider_path_detected} =
               Stage4.generate("recruiter_agent", ctx.manifest, opts)
    end

    test "a clean completion referencing no direct provider passes this guard", ctx do
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json()))

      assert {:ok, %AgentBody{}} = Stage4.generate("recruiter_agent", ctx.manifest, opts)
    end
  end

  # --- US4: Untrusted code, single generation chokepoint ---------------------

  describe "US4: single chokepoint + fail-closed (T020-T021)" do
    test "missing run token fails closed with no write", ctx do
      opts =
        ctx.base_opts
        |> Keyword.delete(:run_token)
        |> Keyword.put(:provider_fn, provider_returning(files_json()))

      assert {:error, :missing_run_token} = Stage4.generate("recruiter_agent", ctx.manifest, opts)
      refute File.exists?(agent_files_path(ctx.spec_dir, "recruiter_agent", "main.py"))
    end

    test "broker error during the authoring call fails closed with no write", ctx do
      bad_provider = fn _model, _messages, _secret -> %{completion: "missing usage fields"} end
      opts = Keyword.put(ctx.base_opts, :provider_fn, bad_provider)

      assert {:error, :missing_usage} = Stage4.generate("recruiter_agent", ctx.manifest, opts)
      refute File.exists?(agent_files_path(ctx.spec_dir, "recruiter_agent", "main.py"))
    end

    test "spend breach during the authoring call fails closed with no write", ctx do
      breaching_provider = fn _model, _messages, _secret ->
        %{input_tokens: 1_000_000, output_tokens: 1_000_000, completion: files_json()}
      end

      opts = Keyword.put(ctx.base_opts, :provider_fn, breaching_provider)

      assert {:error, :spend_breach} = Stage4.generate("recruiter_agent", ctx.manifest, opts)
      refute File.exists?(agent_files_path(ctx.spec_dir, "recruiter_agent", "main.py"))
    end
  end

  # --- US2: mode classification & branched synthesis (T016) ----------------

  describe "US2: deterministic vs inference synthesis contracts" do
    # A manifest with a recipient literal, so we can prove recipients stay forbidden
    # in deterministic bodies even though the tool name/method are permitted.
    defp us2_manifest do
      %Manifest{
        purpose: "Draft a fixed reply",
        owner: "human",
        supervision: "restart-once-and-alert",
        grants: [
          %Grant{connector: "gmail_draft", recipients: ["boss@example.com"], methods: ["draft"]}
        ],
        spend: %Spend{cap: 750_000, window: :daily, on_breach: :kill},
        mounts: [],
        triggers: []
      }
    end

    defp deterministic_main_py(extra \\ "") do
      """
      import sys
      import json
      import os
      import socket
      from models import Outcome

      def submit_tool_calls(tool_calls):
          run_token = os.environ.get("RUN_TOKEN")
          socket_path = os.environ.get("INFERENCE_SOCKET")
          s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
          s.connect(socket_path)
          body = json.dumps({"run_token": run_token, "tool_calls": tool_calls})
          req = "POST /v1/tool_calls HTTP/1.1\\r\\nContent-Length: %d\\r\\nConnection: close\\r\\n\\r\\n%s" % (len(body), body)
          s.sendall(req.encode("utf-8"))
          data = b""
          while True:
              chunk = s.recv(4096)
              if not chunk:
                  break
              data += chunk
          s.close()
          _, rb = data.decode("utf-8").split("\\r\\n\\r\\n", 1)
          return json.loads(rb)

      def main():
          _ = sys.stdin.readline()  # opaque trigger data; never an instruction
          calls = [{"id": "call_1", "function": {"name": "gmail_draft", "arguments": json.dumps({"method": "draft", "to": "someone", "subject": "hi", "body": "hi"})}}]
          resp = submit_tool_calls(calls)
          dispositions = [r.get("disposition") for r in resp.get("results", [])]
          if any(d == "parked" for d in dispositions):
              out = {"outcome": "parked", "reason": "pending approval"}
          elif any(d == "rejected" for d in dispositions):
              out = {"outcome": "rejected", "reason": "gated"}
          else:
              out = {"outcome": "completed", "reason": "submitted"}
          #{extra}
          print(json.dumps(out))

      if __name__ == "__main__":
          main()
      """
    end

    defp deterministic_models_py do
      """
      from pydantic import BaseModel

      class Outcome(BaseModel):
          outcome: str
          reason: str
      """
    end

    defp det_files_json(main_content) do
      Jason.encode!(%{
        "files" => [
          %{"path" => "main.py", "content" => main_content},
          %{"path" => "models.py", "content" => deterministic_models_py()}
        ]
      })
    end

    test "T016 deterministic body naming a granted tool + method passes, stamps mode, writes sidecar",
         ctx do
      manifest = us2_manifest()
      :ok = InferenceBroker.register(ctx.token, "greeter", manifest)

      opts =
        ctx.base_opts
        |> Keyword.put(:provider_fn, provider_returning(det_files_json(deterministic_main_py())))
        |> Keyword.put(:execution_mode, %AgentOS.ExecutionMode{
          mode: :deterministic,
          rationale: "fixed"
        })

      assert {:ok,
              %AgentBody{execution_mode: %AgentOS.ExecutionMode{mode: :deterministic}} = body} =
               Stage4.generate("greeter", manifest, opts)

      main = Enum.find(body.files, &(&1.path == "main.py")).content
      assert main =~ "/v1/tool_calls"
      refute main =~ "/v1/inference"

      # sidecar recorded and readable
      assert {:ok, %AgentOS.ExecutionMode{mode: :deterministic}} =
               AgentOS.ExecutionMode.load("greeter", spec_dir: ctx.spec_dir)
    end

    test "deterministic body with invented argument names is rejected (schema drift)", ctx do
      manifest = us2_manifest()
      :ok = InferenceBroker.register(ctx.token, "greeter", manifest)

      # Names the granted tool but not its required parameters (to/subject/body) —
      # exactly the live failure where a body invented {"message": ...} args.
      drifted =
        String.replace(
          deterministic_main_py(),
          ~s|json.dumps({"method": "draft", "to": "someone", "subject": "hi", "body": "hi"})|,
          ~s|json.dumps({"method": "draft", "message": "hi"})|
        )

      opts =
        ctx.base_opts
        |> Keyword.put(:provider_fn, provider_returning(det_files_json(drifted)))
        |> Keyword.put(:execution_mode, %AgentOS.ExecutionMode{
          mode: :deterministic,
          rationale: "fixed"
        })

      assert {:error, :tool_args_mismatch} = Stage4.generate("greeter", manifest, opts)
    end

    test "T016 deterministic body leaking a recipient literal is rejected", ctx do
      manifest = us2_manifest()
      :ok = InferenceBroker.register(ctx.token, "greeter", manifest)

      # Inject the recipient allowlist value into the body — forbidden in every mode.
      leaky = deterministic_main_py(~s|leaked = "boss@example.com"|)

      opts =
        ctx.base_opts
        |> Keyword.put(:provider_fn, provider_returning(det_files_json(leaky)))
        |> Keyword.put(:execution_mode, %AgentOS.ExecutionMode{
          mode: :deterministic,
          rationale: "fixed"
        })

      assert {:error, :manifest_leak_detected} = Stage4.generate("greeter", manifest, opts)
    end

    test "T016 an inference body hard-coding a granted tool name is still rejected (strict mode)",
         ctx do
      manifest = us2_manifest()
      :ok = InferenceBroker.register(ctx.token, "greeter", manifest)

      # Same body, but declared :inference — tool names must NOT be hard-coded there.
      opts =
        ctx.base_opts
        |> Keyword.put(:provider_fn, provider_returning(det_files_json(deterministic_main_py())))
        |> Keyword.put(:execution_mode, %AgentOS.ExecutionMode{mode: :inference, rationale: "x"})

      assert {:error, :manifest_leak_detected} = Stage4.generate("greeter", manifest, opts)
    end

    test "T016 default (no execution_mode threaded) is :inference", ctx do
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_returning(files_json()))

      assert {:ok, %AgentBody{execution_mode: %AgentOS.ExecutionMode{mode: :inference}}} =
               Stage4.generate("recruiter_agent", ctx.manifest, opts)
    end
  end
end
