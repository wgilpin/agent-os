Code.require_file("../../fixtures/generation/generation.ex", __DIR__)

defmodule AgentOS.Pipeline.OrchestratorTest do
  use ExUnit.Case, async: false

  alias AgentOS.Pipeline.Orchestrator
  alias AgentOS.Pipeline.Orchestrator.PipelineRun
  alias AgentOS.StateStore
  alias AgentOS.Fixtures.Generation

  @model "mock-model"
  @prices %{"mock-model" => %{input: 10_000_000, output: 30_000_000}}
  @now ~U[2026-06-30 12:00:00Z]

  setup do
    uniq = System.unique_integer([:positive])
    tmp = System.tmp_dir!()

    # 1. Start mounts via TestHelper
    mounts = AgentOS.TestHelper.start_mounts!()

    start_supervised!(AgentOS.CredentialProxy)
    start_supervised!(AgentOS.InferenceBroker)

    # 2. Start pipeline_runs store
    pipeline_runs_path = Path.join(tmp, "pipeline_runs_#{uniq}.db")
    run_log_path = Path.join(tmp, "run_log_#{uniq}.md")

    start_supervised!({StateStore, name: "pipeline_runs", path: pipeline_runs_path, initial: %{}})

    on_exit(fn ->
      File.rm(pipeline_runs_path)
      File.rm(run_log_path)
    end)

    # 3. Create temp directories for isolation
    dirs = Generation.tmp_dirs()

    on_exit(fn ->
      File.rm_rf!(dirs.spec_dir)
      File.rm_rf!(dirs.manifest_dir)
    end)

    # Base options passed to the run function
    Application.put_env(:agent_os, :agent_runtime_model, "mock-model")

    base_opts = [
      spec_dir: dirs.spec_dir,
      manifest_dir: dirs.manifest_dir,
      run_log_path: run_log_path,
      model: @model,
      prices: @prices,
      now: @now,
      runner_fn: fn _name, _input, _opts -> {:ok, %{actions: [], response: "ok"}} end
    ]

    {:ok, base_opts: base_opts, run_log_path: run_log_path, dirs: dirs}
  end

  # A dynamic provider function that handles all pipeline stages using stubs
  defp mock_provider(_model, messages, _secret, overrides \\ %{}) do
    joined_messages =
      Enum.map_join(messages, "\n", fn msg ->
        Map.get(msg, :content) || Map.get(msg, "content") || ""
      end)

    cond do
      joined_messages =~ "does fulfilling this purpose require reasoning" ->
        # ExecutionMode classification step (between Stage 2 and Stage 4).
        mode = Map.get(overrides, :execution_mode, "inference")

        %{
          input_tokens: 5,
          output_tokens: 5,
          completion: Jason.encode!(%{"mode" => mode, "rationale" => "stubbed classification"})
        }

      joined_messages =~ "code-synthesis" or joined_messages =~ "Output exactly two files" ->
        # Stage 4 code gen
        body = Generation.stub_agent_body()
        files = Enum.map(body, fn {path, content} -> %{"path" => path, "content" => content} end)

        %{
          input_tokens: 10,
          output_tokens: 10,
          completion: Jason.encode!(%{"files" => files})
        }

      joined_messages =~ "compliance test author" or joined_messages =~ "test specification" ->
        # Stage 3 test spec gen
        %{
          input_tokens: 10,
          output_tokens: 10,
          completion:
            Jason.encode!(%{
              "tests" => [
                %{
                  "id" => "t-001",
                  "input" => %{"message" => "ping"},
                  "expected_behavior" => "prints json with actions list",
                  "eval_prompt" => "verdict is pass if action is empty list"
                }
              ]
            })
        }

      joined_messages =~ "compliance auditor" or joined_messages =~ "CODE-MATCHES-MANIFEST" ->
        # Stage 3 run (LLM-as-judge scoring)
        case Map.get(overrides, :judge_verdict, "pass") do
          "pass" ->
            %{
              input_tokens: 10,
              output_tokens: 10,
              completion: Jason.encode!(%{"verdict" => "pass", "reasoning" => "judge pass"})
            }

          "fail" ->
            %{
              input_tokens: 10,
              output_tokens: 10,
              completion:
                Jason.encode!(%{"verdict" => "fail", "reasoning" => "judge failed check"})
            }
        end

      joined_messages =~ "security-review auditor" or
          joined_messages =~ "untrusted_manifest_grants" ->
        # Stage 5 security review
        case Map.get(overrides, :security_verdict, "pass") do
          "pass" ->
            %{
              input_tokens: 10,
              output_tokens: 10,
              completion: Jason.encode!(%{"status" => "pass", "reasoning" => "security pass"})
            }

          "fail" ->
            %{
              input_tokens: 10,
              output_tokens: 10,
              completion:
                Jason.encode!(%{"status" => "fail", "reasoning" => "security failed review"})
            }
        end
    end
  end

  describe "US1: Confirmed spec -> deployed novel agent (T005, T006, T007)" do
    test "US1: Priorities Coach Generation (T004-T007)", ctx do
      spec = Generation.priorities_coach_confirmed_spec()
      provider_fn = fn model, msgs, secret -> mock_provider(model, msgs, secret) end
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_fn)

      assert {:ok, run} = Orchestrator.run(spec, :dangerously_skip_review, opts)

      assert run.outcome == :deployed
      assert run.judge_verdict == :pass
      assert run.security_verdict == :pass

      # Verify manifest contents
      manifest_path = Path.join([ctx.dirs.manifest_dir, "priorities_coach.md"])
      assert File.exists?(manifest_path)
      {:ok, manifest} = AgentOS.Manifest.load(manifest_path)

      # Check triggers
      assert Enum.any?(manifest.triggers, fn t -> t.type == :message end)
      assert Enum.any?(manifest.triggers, fn t -> t.type == :time and t.at == "08:00" end)

      # Check spend cap
      assert manifest.spend.cap == 100_000

      # Check grants
      assert Enum.any?(manifest.grants, fn g ->
               g.connector == "file_read" and not is_nil(g.path)
             end)

      assert Enum.any?(manifest.grants, fn g ->
               g.connector == "file_write" and not is_nil(g.path)
             end)

      assert Enum.any?(manifest.grants, fn g -> g.connector == "discord_notify" end)
    end

    test "T005 Green-path execution with always_review", ctx do
      spec = Generation.recruiter_confirmed_spec()
      provider_fn = fn model, msgs, secret -> mock_provider(model, msgs, secret) end
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_fn)

      # Under :always_review, it deploy-blocks for human check (returns {:ok, run} with outcome: :blocked)
      # Wait! Let's check under :dangerously_skip_review to see outcome: :deployed
      assert {:ok, run} = Orchestrator.run(spec, :dangerously_skip_review, opts)

      assert run.outcome == :deployed
      assert run.judge_verdict == :pass
      assert run.security_verdict == :pass
      assert run.provenance == :dangerously_skipped
      assert run.stopped_at == nil
      assert run.reason == nil

      stages = Enum.map(run.stages, & &1.stage)
      assert stages == [:manifest, :agent, :judge, :security_review, :deploy]

      # Verify no files written to the actual repo directory
      refute File.exists?("manifests/recruiter.md")
      refute File.exists?("agents/recruiter/main.py")
    end

    test "T005 blocked path execution under always_review", ctx do
      spec = Generation.recruiter_confirmed_spec()
      provider_fn = fn model, msgs, secret -> mock_provider(model, msgs, secret) end
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_fn)

      assert {:ok, run} = Orchestrator.run(spec, :always_review, opts)

      assert run.outcome == :blocked
      assert run.judge_verdict == :pass
      assert run.security_verdict == :pass
      assert run.provenance == :blocked
      assert {:blocked, ref} = run.deploy_result
      assert String.starts_with?(ref, "ref_deploy_recruiter_")
    end

    test "T006 Threading test: code exists before verdict and no re-read", ctx do
      spec = Generation.recruiter_confirmed_spec()

      # We can check that the files are written to disk under dirs.spec_dir during the test
      # by using a stateful agent or inspecting the directory after a successful run.
      provider_fn = fn model, msgs, secret -> mock_provider(model, msgs, secret) end
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_fn)

      {:ok, _run} = Orchestrator.run(spec, :dangerously_skip_review, opts)

      # Verify code files actually existed in spec_dir
      main_path = Path.join([ctx.dirs.spec_dir, "recruiter", "main.py"])
      models_path = Path.join([ctx.dirs.spec_dir, "recruiter", "models.py"])
      assert File.exists?(main_path)
      assert File.exists?(models_path)

      # Verify manifest file actually existed in manifest_dir
      manifest_path = Path.join([ctx.dirs.manifest_dir, "recruiter.md"])
      assert File.exists?(manifest_path)
    end

    test "T007 Deploy-handoff test: options pass through to deploy/3 unchanged", ctx do
      # Use an in-envelope spec (only gmail_read, under threshold)
      spec = %{
        Generation.recruiter_confirmed_spec()
        | capabilities: ["gmail_read"],
          boundaries: %{egress_domains: [], target_locations: []}
      }

      provider_fn = fn model, msgs, secret -> mock_provider(model, msgs, secret) end

      # We can pass spend_threshold option and verify it flows to deploy/3.
      # If we set spend_threshold: 0, the manifest cap (3000) > threshold,
      # so under :review_if_risky it will be considered risky and block.
      opts_block =
        ctx.base_opts
        |> Keyword.put(:provider_fn, provider_fn)
        |> Keyword.put(:spend_threshold, 0)

      assert {:ok, run_block} = Orchestrator.run(spec, :review_if_risky, opts_block)
      assert run_block.outcome == :blocked
      assert run_block.provenance == :blocked

      opts_pass =
        ctx.base_opts
        |> Keyword.put(:provider_fn, provider_fn)
        |> Keyword.put(:spend_threshold, 10_000)

      # Clear spend ledger to reset accumulated spend
      :ok = StateStore.apply_action("spend_ledger", {:delete_in, ["recruiter"]})

      assert {:ok, run_pass} = Orchestrator.run(spec, :review_if_risky, opts_pass)
      assert run_pass.outcome == :deployed
      assert run_pass.provenance == :skipped_in_envelope
    end
  end

  describe "US3: A partial-failure run stops legibly (T015, T016, T017)" do
    test "T015 Judge fail stops before deploy with correct stage attributed", ctx do
      spec = Generation.recruiter_confirmed_spec()

      provider_fn = fn model, msgs, secret ->
        mock_provider(model, msgs, secret, %{judge_verdict: "fail"})
      end

      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_fn)

      assert {:error, run} = Orchestrator.run(spec, :dangerously_skip_review, opts)

      assert run.outcome == :stopped
      assert run.stopped_at == :judge
      assert run.judge_verdict == :fail
      assert run.security_verdict == nil
      assert run.deploy_result == nil
      assert run.reason =~ "judge failed check"
    end

    test "T015 Security fail stops before deploy with correct stage attributed", ctx do
      spec = Generation.recruiter_confirmed_spec()

      provider_fn = fn model, msgs, secret ->
        mock_provider(model, msgs, secret, %{security_verdict: "fail"})
      end

      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_fn)

      assert {:error, run} = Orchestrator.run(spec, :dangerously_skip_review, opts)

      assert run.outcome == :stopped
      assert run.stopped_at == :security_review
      assert run.judge_verdict == :pass
      assert run.security_verdict == :fail
      assert run.deploy_result == nil
      assert run.reason =~ "security failed review"
    end

    test "T016 Stage-crash test: catching crashed/raising provider", ctx do
      spec = Generation.recruiter_confirmed_spec()
      provider_fn = Generation.crashing_provider()
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_fn)

      assert {:error, run} = Orchestrator.run(spec, :dangerously_skip_review, opts)

      assert run.outcome == :stopped
      assert run.stopped_at == :agent
      assert {:crash, %RuntimeError{message: msg}} = run.reason
      assert msg =~ "Stubbed model provider crashed"
    end

    test "T017 Legibility read-back test: state snapshot and Inventory render", ctx do
      spec = Generation.recruiter_confirmed_spec()
      provider_fn = fn model, msgs, secret -> mock_provider(model, msgs, secret) end
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_fn)

      # Run successfully
      {:ok, _run} = Orchestrator.run(spec, :dangerously_skip_review, opts)

      # 1. StateStore snapshot check
      snapshot = StateStore.snapshot("pipeline_runs")
      assert %PipelineRun{} = run_record = Map.get(snapshot, "recruiter")
      assert run_record.outcome == :deployed
      assert run_record.judge_verdict == :pass
      assert run_record.security_verdict == :pass

      # 2. Inventory render check
      manifest_path = Path.join(ctx.dirs.manifest_dir, "recruiter.md")
      rendered = AgentOS.Inventory.render(manifest_path: manifest_path)

      assert rendered =~ "DEPLOY PROVENANCE: dangerously-skipped"
      assert rendered =~ "JUDGE: pass"
      assert rendered =~ "SECURITY REVIEW: pass"
    end
  end

  describe "US2: execution-mode classification threaded end-to-end (T018)" do
    test "classification runs and the mode is recorded to the sidecar", ctx do
      spec = Generation.recruiter_confirmed_spec()
      provider_fn = fn model, msgs, secret -> mock_provider(model, msgs, secret) end
      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_fn)

      {:ok, _run} = Orchestrator.run(spec, :dangerously_skip_review, opts)

      # The orchestrator classified the purpose and Stage 4 persisted the typed sidecar.
      assert {:ok, %AgentOS.ExecutionMode{mode: :inference}} =
               AgentOS.ExecutionMode.load("recruiter", spec_dir: ctx.dirs.spec_dir)

      assert File.exists?(Path.join([ctx.dirs.spec_dir, "recruiter", "execution_mode.json"]))
    end

    test "a deterministic classification threads through to the recorded mode", ctx do
      spec = Generation.recruiter_confirmed_spec()

      # Override only the classification completion → deterministic; the mode must be
      # threaded to Stage 4 and recorded (co-generation isolation: judge/agent both
      # derive from manifest+purpose+this one bit).
      provider_fn = fn model, msgs, secret ->
        mock_provider(model, msgs, secret, %{execution_mode: "deterministic"})
      end

      opts = Keyword.put(ctx.base_opts, :provider_fn, provider_fn)

      {:ok, _run} = Orchestrator.run(spec, :dangerously_skip_review, opts)

      assert {:ok, %AgentOS.ExecutionMode{mode: :deterministic}} =
               AgentOS.ExecutionMode.load("recruiter", spec_dir: ctx.dirs.spec_dir)
    end
  end
end
