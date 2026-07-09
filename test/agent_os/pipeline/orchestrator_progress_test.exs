Code.require_file("../../fixtures/generation/generation.ex", __DIR__)

defmodule AgentOS.Pipeline.OrchestratorProgressTest do
  @moduledoc """
  T014: the orchestrator broadcasts typed ProgressEvent structs on AgentOS.PubSub —
  stage started/finished, verdicts, and exactly one terminal outcome — keyed per
  run, and persists the run_id so a refreshed UI can reconstruct and re-subscribe
  (FR-003/FR-010). All providers stubbed (Constitution IV).
  """
  use ExUnit.Case, async: false

  alias AgentOS.Fixtures.Generation
  alias AgentOS.Pipeline.Orchestrator
  alias AgentOS.Pipeline.Orchestrator.PipelineRun
  alias AgentOS.Pipeline.ProgressEvent
  alias AgentOS.StateStore

  @model "mock-model"
  @prices %{"mock-model" => %{input: 10_000_000, output: 30_000_000}}
  @now ~U[2026-06-30 12:00:00Z]

  setup do
    uniq = System.unique_integer([:positive])
    tmp = System.tmp_dir!()

    AgentOS.TestHelper.start_mounts!()
    start_supervised!(AgentOS.CredentialProxy)
    start_supervised!(AgentOS.InferenceBroker)

    # The progress channel under test.
    start_supervised!({Phoenix.PubSub, name: AgentOS.PubSub})

    pipeline_runs_path = Path.join(tmp, "pipeline_runs_#{uniq}.db")
    run_log_path = Path.join(tmp, "run_log_#{uniq}.md")

    start_supervised!({StateStore, name: "pipeline_runs", path: pipeline_runs_path, initial: %{}})

    on_exit(fn ->
      File.rm(pipeline_runs_path)
      File.rm(run_log_path)
    end)

    dirs = Generation.tmp_dirs()

    on_exit(fn ->
      File.rm_rf!(dirs.spec_dir)
      File.rm_rf!(dirs.manifest_dir)
    end)

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

    {:ok, base_opts: base_opts}
  end

  # Stage-aware stub provider covering classification, synthesis, judging, and review.
  defp mock_provider(_model, messages, _secret, overrides) do
    joined =
      Enum.map_join(messages, "\n", fn msg ->
        Map.get(msg, :content) || Map.get(msg, "content") || ""
      end)

    cond do
      joined =~ "does fulfilling this purpose require reasoning" ->
        %{
          input_tokens: 5,
          output_tokens: 5,
          completion: Jason.encode!(%{"mode" => "inference", "rationale" => "stubbed"})
        }

      joined =~ "code-synthesis" or joined =~ "Output exactly two files" ->
        body = Generation.stub_agent_body()
        files = Enum.map(body, fn {path, content} -> %{"path" => path, "content" => content} end)

        %{
          input_tokens: 10,
          output_tokens: 10,
          completion: Jason.encode!(%{"files" => files})
        }

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
                  "expected_behavior" => "prints json with actions list",
                  "eval_prompt" => "verdict is pass if action is empty list"
                }
              ]
            })
        }

      joined =~ "compliance auditor" or joined =~ "CODE-MATCHES-MANIFEST" ->
        verdict = Map.get(overrides, :judge_verdict, "pass")

        %{
          input_tokens: 10,
          output_tokens: 10,
          completion: Jason.encode!(%{"verdict" => verdict, "reasoning" => "judge #{verdict}"})
        }

      joined =~ "security-review auditor" or joined =~ "untrusted_manifest_grants" ->
        %{
          input_tokens: 10,
          output_tokens: 10,
          completion: Jason.encode!(%{"status" => "pass", "reasoning" => "security pass"})
        }
    end
  end

  defp opts_with_provider(base_opts, run_id, overrides \\ %{}) do
    base_opts
    |> Keyword.put(:provider_fn, fn model, msgs, secret ->
      mock_provider(model, msgs, secret, overrides)
    end)
    |> Keyword.put(:run_id, run_id)
  end

  # Drains all pipeline_progress events from the mailbox.
  defp collect_events(acc \\ []) do
    receive do
      {:pipeline_progress, %ProgressEvent{} = event} -> collect_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a deployed run emits started/finished per stage, verdicts, and one terminal event",
       ctx do
    run_id = "run_progress_#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(AgentOS.PubSub, ProgressEvent.run_topic(run_id))

    spec = Generation.recruiter_confirmed_spec()

    assert {:ok, %PipelineRun{outcome: :deployed}} =
             Orchestrator.run(
               spec,
               :dangerously_skip_review,
               opts_with_provider(ctx.base_opts, run_id)
             )

    events = collect_events()

    # Every event is typed and keyed to this run.
    assert Enum.all?(
             events,
             &match?(%ProgressEvent{run_id: ^run_id, agent_name: "recruiter"}, &1)
           )

    # Each executed stage has a started and a finished event.
    for stage <- [:manifest, :agent, :judge, :security_review, :deploy] do
      assert Enum.any?(events, &(&1.stage == stage and &1.status == :started)),
             "missing #{stage} :started"

      assert Enum.any?(events, &(&1.stage == stage and &1.status == :finished)),
             "missing #{stage} :finished"
    end

    # Verdict-bearing stages carry the verdict in detail.
    assert Enum.any?(
             events,
             &(&1.stage == :judge and &1.status == :finished and &1.detail == :pass)
           )

    assert Enum.any?(
             events,
             &(&1.stage == :security_review and &1.status == :finished and &1.detail == :pass)
           )

    # Exactly one terminal event: deployed.
    terminal = Enum.filter(events, &(&1.stage == :pipeline))
    assert [%ProgressEvent{status: :deployed, detail: :dangerously_skipped}] = terminal
  end

  test "a blocked consent-gated run terminates with a :blocked event carrying the ref", ctx do
    run_id = "run_blocked_#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(AgentOS.PubSub, ProgressEvent.run_topic(run_id))

    spec = Generation.recruiter_confirmed_spec()

    assert {:ok, %PipelineRun{outcome: :blocked}} =
             Orchestrator.run(spec, :always_review, opts_with_provider(ctx.base_opts, run_id))

    events = collect_events()
    terminal = Enum.filter(events, &(&1.stage == :pipeline))
    assert [%ProgressEvent{status: :blocked, detail: ref}] = terminal
    assert is_binary(ref) and String.starts_with?(ref, "ref_deploy_recruiter_")
  end

  test "a failing judge stops the run with a :failed stage event and a :stopped terminal", ctx do
    run_id = "run_stopped_#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(AgentOS.PubSub, ProgressEvent.run_topic(run_id))

    spec = Generation.recruiter_confirmed_spec()

    assert {:error, %PipelineRun{outcome: :stopped, stopped_at: :judge}} =
             Orchestrator.run(
               spec,
               :dangerously_skip_review,
               opts_with_provider(ctx.base_opts, run_id, %{judge_verdict: "fail"})
             )

    events = collect_events()

    assert Enum.any?(events, &(&1.stage == :judge and &1.status == :failed))

    terminal = Enum.filter(events, &(&1.stage == :pipeline))
    assert [%ProgressEvent{status: :stopped, detail: detail}] = terminal
    assert detail =~ "judge fail"

    # No deploy stage ever started.
    refute Enum.any?(events, &(&1.stage == :deploy))
  end

  test "events also land on the firehose topic for the inventory", ctx do
    run_id = "run_firehose_#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(AgentOS.PubSub, ProgressEvent.all_topic())

    spec = Generation.recruiter_confirmed_spec()

    assert {:ok, _run} =
             Orchestrator.run(
               spec,
               :dangerously_skip_review,
               opts_with_provider(ctx.base_opts, run_id)
             )

    events = collect_events()
    assert Enum.any?(events, &(&1.run_id == run_id and &1.stage == :pipeline))
  end

  test "events are keyed per run — a subscriber to another run's topic hears nothing", ctx do
    run_id = "run_isolated_#{System.unique_integer([:positive])}"
    other_topic = ProgressEvent.run_topic("run_other_#{System.unique_integer([:positive])}")
    :ok = Phoenix.PubSub.subscribe(AgentOS.PubSub, other_topic)

    spec = Generation.recruiter_confirmed_spec()

    assert {:ok, _run} =
             Orchestrator.run(
               spec,
               :dangerously_skip_review,
               opts_with_provider(ctx.base_opts, run_id)
             )

    assert collect_events() == []
  end

  test "the persisted PipelineRun carries the run_id for refresh reconstruction", ctx do
    run_id = "run_persisted_#{System.unique_integer([:positive])}"
    spec = Generation.recruiter_confirmed_spec()

    assert {:ok, _run} =
             Orchestrator.run(
               spec,
               :dangerously_skip_review,
               opts_with_provider(ctx.base_opts, run_id)
             )

    snapshot = StateStore.snapshot("pipeline_runs")
    assert %PipelineRun{run_id: ^run_id} = Map.get(snapshot, "recruiter")
  end

  test "a run without an explicit run_id generates one and still persists it", ctx do
    spec = Generation.recruiter_confirmed_spec()

    provider_opts =
      Keyword.put(ctx.base_opts, :provider_fn, fn model, msgs, secret ->
        mock_provider(model, msgs, secret, %{})
      end)

    assert {:ok, %PipelineRun{run_id: run_id}} =
             Orchestrator.run(spec, :dangerously_skip_review, provider_opts)

    assert is_binary(run_id) and run_id != ""

    snapshot = StateStore.snapshot("pipeline_runs")
    assert %PipelineRun{run_id: ^run_id} = Map.get(snapshot, "recruiter")
  end
end
