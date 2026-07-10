Code.require_file("../../fixtures/generation/generation.ex", __DIR__)

defmodule AgentOS.Pipeline.RerunTest do
  use ExUnit.Case, async: false

  alias AgentOS.Pipeline.Rerun
  alias AgentOS.Pipeline.Rerun.Record
  alias AgentOS.Pipeline.ProgressEvent
  alias AgentOS.{Provisioner, StateStore, Manifest}
  alias AgentOS.Fixtures.Generation

  @model "mock-model"
  @prices %{"mock-model" => %{input: 10_000_000, output: 30_000_000}}
  @now ~U[2026-07-10 12:00:00Z]

  setup do
    uniq = System.unique_integer([:positive])
    tmp = System.tmp_dir!()

    # start_mounts! provides judge_results, security_review_results, provenance, deployments.
    AgentOS.TestHelper.start_mounts!()
    start_supervised!(AgentOS.CredentialProxy)
    start_supervised!(AgentOS.InferenceBroker)

    check_reruns_path = Path.join(tmp, "check_reruns_#{uniq}.db")
    start_supervised!({StateStore, name: "check_reruns", path: check_reruns_path, initial: %{}})
    on_exit(fn -> File.rm(check_reruns_path) end)

    # PubSub so progress-event broadcasts have a live registry (US4 asserts them).
    if Process.whereis(AgentOS.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: AgentOS.PubSub})
    end

    Application.put_env(:agent_os, :agent_runtime_model, @model)

    dirs = Generation.tmp_dirs()

    on_exit(fn ->
      File.rm_rf!(dirs.spec_dir)
      File.rm_rf!(dirs.manifest_dir)
    end)

    {:ok, dirs: dirs}
  end

  # Projects a valid manifest, writes the agent's code files, and returns {agent_name, opts}.
  # `spend_cap` overrides the manifest cap so the spend-lift behaviour can be exercised.
  defp setup_agent(dirs, opts \\ []) do
    agent_name = Keyword.get(opts, :agent_name, "coach")
    spend_cap = Keyword.get(opts, :spend_cap)

    {:ok, manifest} = Manifest.Projection.project(Generation.priorities_coach_confirmed_spec())

    manifest =
      if spend_cap, do: %{manifest | spend: %{manifest.spend | cap: spend_cap}}, else: manifest

    manifest_path = Path.join(dirs.manifest_dir, "#{agent_name}.md")
    :ok = Manifest.Projection.write(manifest, manifest_path)

    agent_dir = Path.join(dirs.spec_dir, agent_name)
    File.mkdir_p!(agent_dir)
    body = Generation.stub_agent_body()
    File.write!(Path.join(agent_dir, "main.py"), body["main.py"])
    File.write!(Path.join(agent_dir, "models.py"), body["models.py"])

    {agent_name, agent_name}
  end

  # Base stage opts: reused stubbed runner (no PortRunner), deterministic clock/prices.
  defp base_opts(dirs, provider_fn) do
    [
      spec_dir: dirs.spec_dir,
      manifest_dir: dirs.manifest_dir,
      model: @model,
      prices: @prices,
      now: @now,
      provider_fn: provider_fn,
      runner_fn: fn _name, _input, _opts -> {:ok, %{actions: [], response: "ok"}} end
    ]
  end

  # Branching provider covering judge synthesis, judge eval, and security review, with
  # per-call overrides for the judge/security verdicts (mirrors orchestrator_test).
  defp mock_provider(_model, messages, _secret, overrides \\ %{}) do
    joined =
      Enum.map_join(messages, "\n", fn m ->
        Map.get(m, :content) || Map.get(m, "content") || ""
      end)

    cond do
      joined =~ "compliance test author" or joined =~ "test specification" ->
        %{
          input_tokens: 10,
          output_tokens: 10,
          completion:
            Jason.encode!(%{
              "tests" => [
                %{
                  "id" => "t-001",
                  "input" => %{"message" => "ping"},
                  "expected_behavior" => "acts within grants",
                  "eval_prompt" => "pass if contained"
                }
              ]
            })
        }

      joined =~ "compliance auditor" or joined =~ "CODE-MATCHES-MANIFEST" ->
        verdict = Map.get(overrides, :judge, "pass")

        %{
          input_tokens: 10,
          output_tokens: 10,
          completion: Jason.encode!(%{"verdict" => verdict, "reasoning" => "judge #{verdict}"})
        }

      joined =~ "security-review auditor" or joined =~ "untrusted_manifest_grants" ->
        verdict = Map.get(overrides, :security, "pass")

        %{
          input_tokens: 10,
          output_tokens: 10,
          completion: Jason.encode!(%{"status" => verdict, "reasoning" => "security #{verdict}"})
        }
    end
  end

  defp provider(overrides \\ %{}) do
    fn model, msgs, secret -> mock_provider(model, msgs, secret, overrides) end
  end

  describe "US1: recover a stranded agent" do
    test "passing re-run persists fresh verdicts keyed to the code hash and opens the gate", %{
      dirs: dirs
    } do
      {agent, _} = setup_agent(dirs)
      opts = base_opts(dirs, provider())

      assert {:ok, %Record{outcome: :passed} = record} = Rerun.run(agent, opts)

      expected_hash = Provisioner.code_hash(agent, opts)
      assert record.code_hash == expected_hash
      assert record.judge_verdict == :pass
      assert record.security_verdict == :pass

      judge = StateStore.snapshot("judge_results")[agent]
      security = StateStore.snapshot("security_review_results")[agent]
      assert judge.status == :pass
      assert judge.code_hash == expected_hash
      assert security.status == :pass
      assert security.code_hash == expected_hash

      # The green re-run opens the deploy gate — the agent is now approvable.
      assert :ok = Provisioner.deploy_gate(agent, :always_review, opts)

      # And the record was persisted for history.
      assert %Record{outcome: :passed} = StateStore.snapshot("check_reruns")[agent]
    end

    test "re-run does not deploy, approve, or record provenance", %{dirs: dirs} do
      {agent, _} = setup_agent(dirs)
      opts = base_opts(dirs, provider())

      assert {:ok, %Record{outcome: :passed}} = Rerun.run(agent, opts)

      assert is_nil(StateStore.snapshot("deployments")[agent])
      assert is_nil(StateStore.snapshot("provenance")[agent])
    end

    test "a tiny agent spend cap does not block the re-run", %{dirs: dirs} do
      # cap of 1 micro-dollar would kill a runtime run instantly; the setup token is uncapped.
      {agent, _} = setup_agent(dirs, spend_cap: 1)
      opts = base_opts(dirs, provider())

      assert {:ok, %Record{outcome: :passed}} = Rerun.run(agent, opts)
    end
  end

  describe "US2: a failed re-run keeps the agent blocked, visibly" do
    test "failing security review keeps the gate blocked with the reason visible", %{dirs: dirs} do
      {agent, _} = setup_agent(dirs)
      opts = base_opts(dirs, provider(%{security: "fail"}))

      assert {:error, %Record{outcome: :failed} = record} = Rerun.run(agent, opts)
      assert record.judge_verdict == :pass
      assert record.security_verdict == :fail
      assert record.reason =~ "security review"

      assert {:error, :security_review_failed} =
               Provisioner.deploy_gate(agent, :always_review, opts)
    end

    test "an aborted stage yields an incomplete outcome and stays blocked", %{dirs: dirs} do
      {agent, _} = setup_agent(dirs)
      # The security-review provider raises → Stage 5 aborts before a verdict → incomplete.
      raising =
        fn _model, messages, _secret ->
          joined =
            Enum.map_join(messages, "\n", fn m ->
              Map.get(m, :content) || Map.get(m, "content") || ""
            end)

          if joined =~ "security-review auditor" or joined =~ "untrusted_manifest_grants" do
            raise RuntimeError, "boom"
          else
            mock_provider(nil, messages, nil)
          end
        end

      opts = base_opts(dirs, raising)

      assert {:error, %Record{outcome: :incomplete} = record} = Rerun.run(agent, opts)
      assert is_nil(record.security_verdict)
      assert record.reason =~ "security review"

      # Persisted so the owner can retry; gate stays blocked (no passing security verdict).
      assert %Record{outcome: :incomplete} = StateStore.snapshot("check_reruns")[agent]
      assert {:error, _} = Provisioner.deploy_gate(agent, :always_review, opts)
    end
  end

  describe "US4: progress events" do
    test "emits per-check start/finish and a terminal pipeline event", %{dirs: dirs} do
      {agent, _} = setup_agent(dirs)
      run_id = "rerun_test_#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(AgentOS.PubSub, ProgressEvent.run_topic(run_id))

      opts = base_opts(dirs, provider()) |> Keyword.put(:run_id, run_id)
      assert {:ok, %Record{outcome: :passed}} = Rerun.run(agent, opts)

      assert_received {:pipeline_progress, %ProgressEvent{stage: :judge, status: :started}}
      assert_received {:pipeline_progress, %ProgressEvent{stage: :judge, status: :finished}}

      assert_received {:pipeline_progress,
                       %ProgressEvent{stage: :security_review, status: :started}}

      assert_received {:pipeline_progress,
                       %ProgressEvent{stage: :security_review, status: :finished}}

      assert_received {:pipeline_progress, %ProgressEvent{stage: :pipeline, status: :passed}}
    end
  end

  describe "eligibility refusals (FR-008)" do
    test "refuses an agent with no generated code", %{dirs: dirs} do
      {:ok, manifest} = Manifest.Projection.project(Generation.priorities_coach_confirmed_spec())
      :ok = Manifest.Projection.write(manifest, Path.join(dirs.manifest_dir, "orphan.md"))

      assert {:error, :code_missing} =
               Rerun.eligible?("orphan", spec_dir: dirs.spec_dir, manifest_dir: dirs.manifest_dir)
    end

    test "refuses a system agent", %{dirs: dirs} do
      {agent, _} = setup_agent(dirs, agent_name: "sys_rerun")
      original = Application.get_env(:agent_os, :system_agents, [])
      Application.put_env(:agent_os, :system_agents, [agent | original])
      on_exit(fn -> Application.put_env(:agent_os, :system_agents, original) end)

      assert {:error, :system_agent} =
               Rerun.eligible?(agent, spec_dir: dirs.spec_dir, manifest_dir: dirs.manifest_dir)
    end

    test "refuses an agent whose checks already pass for the current code", %{dirs: dirs} do
      {agent, _} = setup_agent(dirs)
      opts = base_opts(dirs, provider())

      # A green run leaves nothing to recover: a second re-run is a paid no-op.
      assert {:ok, %Record{outcome: :passed}} = Rerun.run(agent, opts)

      assert {:error, :checks_green} =
               Rerun.eligible?(agent, spec_dir: dirs.spec_dir, manifest_dir: dirs.manifest_dir)

      assert {:error, :checks_green} = Rerun.start(agent, opts)

      # Touching the code goes stale — the recovery path re-opens.
      File.write!(Path.join([dirs.spec_dir, agent, "main.py"]), "# edited\n")

      assert :ok =
               Rerun.eligible?(agent, spec_dir: dirs.spec_dir, manifest_dir: dirs.manifest_dir)
    end
  end
end
