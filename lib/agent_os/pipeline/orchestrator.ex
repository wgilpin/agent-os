defmodule AgentOS.Pipeline.Orchestrator.PipelineRun do
  @moduledoc """
  Represents the recorded execution context and status of an end-to-end generation run.
  """

  @type stage :: :manifest | :agent | :judge | :security_review | :deploy
  @type stage_status :: :ok | :error
  @type stage_outcome :: %{stage: stage(), status: stage_status(), detail: term()}
  @type deploy_result ::
          {:ok, provenance :: atom()}
          | {:blocked, ref :: String.t()}
          | {:error, term()}

  @type t :: %__MODULE__{
          agent_name: String.t(),
          purpose: String.t(),
          stages: [stage_outcome()],
          judge_verdict: :pass | :fail | :error | nil,
          security_verdict: :pass | :fail | :error | nil,
          deploy_result: deploy_result() | nil,
          provenance:
            :reviewed_human | :skipped_in_envelope | :dangerously_skipped | :blocked | nil,
          outcome: :deployed | :blocked | :stopped,
          stopped_at: stage() | nil,
          reason: term() | nil,
          started_at: DateTime.t(),
          finished_at: DateTime.t()
        }

  defstruct [
    :agent_name,
    :purpose,
    :outcome,
    :stopped_at,
    :reason,
    :started_at,
    :finished_at,
    stages: [],
    judge_verdict: nil,
    security_verdict: nil,
    deploy_result: nil,
    provenance: nil
  ]
end

defmodule AgentOS.Pipeline.Orchestrator do
  @moduledoc """
  Stage-threading orchestrator that runs the end-to-end generation pipeline (Stage 2 -> Stage 6).
  """

  require Logger
  alias AgentOS.Pipeline.Orchestrator.PipelineRun
  alias AgentOS.StateStore

  @doc """
  Runs the end-to-end generation pipeline for a confirmed ElicitedSpec.
  Executes stages sequentially, short-circuiting on any error or check failure.
  """
  @spec run(AgentOS.ElicitedSpec.t(), review_mode :: atom() | String.t()) ::
          {:ok, PipelineRun.t()} | {:error, PipelineRun.t()}
  def run(spec, review_mode \\ :always_review)

  def run(spec, review_mode) do
    run(spec, review_mode, [])
  end

  @doc """
  Runs the end-to-end generation pipeline with options.
  """
  @spec run(AgentOS.ElicitedSpec.t(), review_mode :: atom() | String.t(), opts :: keyword()) ::
          {:ok, PipelineRun.t()} | {:error, PipelineRun.t()}
  def run(spec, review_mode, opts) do
    started_at = DateTime.utc_now()
    agent_name = determine_name(spec, opts)
    spec_dir = Keyword.get(opts, :spec_dir, "agents")
    manifest_dir = Keyword.get(opts, :manifest_dir, "manifests")

    run = %PipelineRun{
      agent_name: agent_name,
      purpose: spec.purpose,
      stages: [],
      started_at: started_at
    }

    if not spec.confirmed do
      failed_run = %{
        run
        | outcome: :stopped,
          stopped_at: :manifest,
          reason: :spec_not_confirmed,
          finished_at: DateTime.utc_now()
      }

      record_run(failed_run, opts)
      {:error, failed_run}
    else
      execute_stages(run, spec, review_mode, spec_dir, manifest_dir, opts)
    end
  end

  # --- Execution loop ---

  defp execute_stages(run, spec, review_mode, spec_dir, manifest_dir, opts) do
    agent_name = run.agent_name

    Logger.info("[Orchestrator] Starting Stage 2: Manifest Projection for '#{agent_name}'...")

    # Stage 2: Manifest projection & write
    case safe_call(
           :manifest,
           fn ->
             case AgentOS.Manifest.Projection.project(spec) do
               {:ok, manifest} ->
                 manifest_path = Path.join(manifest_dir, "#{agent_name}.md")

                 case AgentOS.Manifest.Projection.write(manifest, manifest_path) do
                   :ok -> {:ok, manifest}
                   {:error, reason} -> {:error, reason}
                 end

               {:error, reason} ->
                 {:error, reason}
             end
           end,
           run
         ) do
      {:ok, run, manifest} ->
        # Register metered token with InferenceBroker under the "orchestrator" agent
        # so that code generation/testing costs do not drain the agent's runtime budget.
        run_token =
          opts[:run_token] ||
            "run_token_#{agent_name}_#{System.unique_integer([:positive])}"

        orchestrator_manifest = %AgentOS.Manifest{
          purpose: "Agent OS Pipeline Execution",
          owner: "system",
          supervision: "autonomous",
          grants: [],
          spend: %AgentOS.Manifest.Spend{cap: 1_000_000_000, window: :daily, on_breach: :kill}
        }

        :ok = AgentOS.InferenceBroker.register(run_token, "orchestrator", orchestrator_manifest)

        try do
          opts_with_token = Keyword.put(opts, :run_token, run_token)

          # Classify the purpose ONCE, between manifest projection and synthesis, under
          # the orchestrator's uncapped setup token. The typed mode is threaded to both
          # Stage 4 (synthesis contract) and Stage 3 (judge) via opts, so judge and agent
          # derive independently from manifest + purpose + one substrate-recorded bit —
          # co-generation isolation holds (research D5).
          {:ok, execution_mode} =
            AgentOS.ExecutionMode.classify(agent_name, manifest, opts_with_token)

          Logger.info(
            "[Orchestrator] Classified '#{agent_name}' as #{execution_mode.mode} — #{execution_mode.rationale}"
          )

          opts_with_mode = Keyword.put(opts_with_token, :execution_mode, execution_mode)
          do_pipeline_rest(run, manifest, review_mode, spec_dir, manifest_dir, opts_with_mode)
        after
          AgentOS.InferenceBroker.unregister(run_token)
        end

      {:error, run} ->
        failed_run = %{run | finished_at: DateTime.utc_now()}
        record_run(failed_run, opts)
        {:error, failed_run}
    end
  end

  defp do_pipeline_rest(run, manifest, review_mode, _spec_dir, manifest_dir, opts) do
    agent_name = run.agent_name

    Logger.info("[Orchestrator] Starting Stage 4: Synthesising Agent Body for '#{agent_name}'...")

    # Stage 4: Synthesise Agent Body
    case safe_call(
           :agent,
           fn ->
             case AgentOS.Pipeline.Stage4.generate(agent_name, manifest, opts) do
               {:ok, agent_body} ->
                 code_files =
                   Enum.into(agent_body.files, %{}, fn file -> {file.path, file.content} end)

                 {:ok, code_files}

               {:error, reason} ->
                 {:error, reason}
             end
           end,
           run
         ) do
      {:ok, run, code_files} ->
        Logger.info(
          "[Orchestrator] Starting Stage 3: Generating blind test spec and running compliance checks for '#{agent_name}'..."
        )

        # Stage 3: Generate Blind + Run Judge
        case safe_call(
               :judge,
               fn ->
                 case AgentOS.Pipeline.Stage3.generate(agent_name, manifest, opts) do
                   {:ok, _test_spec} ->
                     case AgentOS.Pipeline.Stage3.run(agent_name, manifest, opts) do
                       {:ok, verdict} ->
                         if verdict.status == :pass do
                           {:ok, verdict}
                         else
                           {:error, {:judge_not_pass, verdict}}
                         end
                     end

                   {:error, reason} ->
                     {:error, reason}
                 end
               end,
               run
             ) do
          {:ok, run, judge_verdict} ->
            run = %{run | judge_verdict: judge_verdict.status}

            Logger.info(
              "[Orchestrator] Starting Stage 5: Performing Security Review for '#{agent_name}'..."
            )

            # Stage 5: Security Review
            case safe_call(
                   :security_review,
                   fn ->
                     case AgentOS.Pipeline.Stage5.review(agent_name, manifest, code_files, opts) do
                       {:ok, verdict} ->
                         if verdict.status == :pass do
                           {:ok, verdict}
                         else
                           {:error, {:security_not_pass, verdict}}
                         end

                       {:error, reason} ->
                         {:error, reason}
                     end
                   end,
                   run
                 ) do
              {:ok, run, security_verdict} ->
                run = %{run | security_verdict: security_verdict.status}

                Logger.info(
                  "[Orchestrator] Starting Stage 6: Deploying agent '#{agent_name}' with review mode '#{review_mode}'..."
                )

                # Stage 6: Deploy
                manifest_path = Path.join(manifest_dir, "#{agent_name}.md")

                case safe_call(
                       :deploy,
                       fn ->
                         case AgentOS.Provisioner.deploy(manifest_path, review_mode, opts) do
                           {:ok, provenance} ->
                             {:ok, {:deployed, provenance}}

                           {:blocked, ref} ->
                             {:ok, {:blocked, ref}}

                           {:error, reason} ->
                             {:error, reason}
                         end
                       end,
                       run
                     ) do
                  {:ok, run, {deploy_outcome, deploy_detail}} ->
                    final_run =
                      case deploy_outcome do
                        :deployed ->
                          %{
                            run
                            | judge_verdict: :pass,
                              security_verdict: :pass,
                              deploy_result: {:ok, deploy_detail},
                              provenance: deploy_detail,
                              outcome: :deployed,
                              finished_at: DateTime.utc_now()
                          }

                        :blocked ->
                          %{
                            run
                            | judge_verdict: :pass,
                              security_verdict: :pass,
                              deploy_result: {:blocked, deploy_detail},
                              provenance: :blocked,
                              outcome: :blocked,
                              finished_at: DateTime.utc_now()
                          }
                      end

                    record_run(final_run, opts)
                    {:ok, final_run}

                  {:error, run} ->
                    failed_run = %{
                      run
                      | judge_verdict: :pass,
                        security_verdict: :pass,
                        finished_at: DateTime.utc_now()
                    }

                    record_run(failed_run, opts)
                    {:error, failed_run}
                end

              {:error, run} ->
                security_status =
                  case run.reason do
                    {:security_not_pass, verdict} -> verdict.status
                    _ -> nil
                  end

                clean_reason =
                  case run.reason do
                    {:security_not_pass, verdict} -> verdict.reasoning
                    other -> other
                  end

                failed_run = %{
                  run
                  | judge_verdict: :pass,
                    security_verdict: security_status,
                    reason: clean_reason,
                    finished_at: DateTime.utc_now()
                }

                record_run(failed_run, opts)
                {:error, failed_run}
            end

          {:error, run} ->
            judge_status =
              case run.reason do
                {:judge_not_pass, verdict} -> verdict.status
                _ -> nil
              end

            clean_reason =
              case run.reason do
                {:judge_not_pass, verdict} -> verdict.reasoning
                other -> other
              end

            failed_run = %{
              run
              | judge_verdict: judge_status,
                reason: clean_reason,
                finished_at: DateTime.utc_now()
            }

            record_run(failed_run, opts)
            {:error, failed_run}
        end

      {:error, run} ->
        failed_run = %{run | finished_at: DateTime.utc_now()}
        record_run(failed_run, opts)
        {:error, failed_run}
    end
  end

  # --- Helper for catching crashes in stages ---

  defp safe_call(stage_name, fun, run) do
    try do
      case fun.() do
        {:ok, result} ->
          new_stages = run.stages ++ [%{stage: stage_name, status: :ok, detail: :ok}]
          {:ok, %{run | stages: new_stages}, result}

        {:error, reason} ->
          new_stages = run.stages ++ [%{stage: stage_name, status: :error, detail: reason}]

          {:error,
           %{
             run
             | stages: new_stages,
               outcome: :stopped,
               stopped_at: stage_name,
               reason: reason
           }}
      end
    rescue
      exception ->
        stacktrace = __STACKTRACE__

        Logger.error(
          "Stage #{stage_name} crashed: #{inspect(exception)}\n#{Exception.format_stacktrace(stacktrace)}"
        )

        new_stages =
          run.stages ++ [%{stage: stage_name, status: :error, detail: {:crash, exception}}]

        {:error,
         %{
           run
           | stages: new_stages,
             outcome: :stopped,
             stopped_at: stage_name,
             reason: {:crash, exception}
         }}
    catch
      :exit, value ->
        Logger.error("Stage #{stage_name} exited: #{inspect(value)}")

        new_stages =
          run.stages ++ [%{stage: stage_name, status: :error, detail: {:exit, value}}]

        {:error,
         %{
           run
           | stages: new_stages,
             outcome: :stopped,
             stopped_at: stage_name,
             reason: {:exit, value}
         }}
    end
  end

  # --- Helpers ---

  defp determine_name(spec, opts) do
    cond do
      name = opts[:agent_name] ->
        to_string(name)

      spec.purpose == "reply to recruiter emails" ->
        "recruiter"

      true ->
        spec.purpose
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9_]+/, "_")
        |> String.trim("_")
    end
  end

  # Private persistence helpers
  defp record_run(run, opts) do
    agent_name = run.agent_name
    run_log_path = Keyword.get(opts, :run_log_path)

    # Persist via StateStore
    try do
      StateStore.apply_action("pipeline_runs", {:put, agent_name, run})
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Format human-readable trace line
    verdicts_str = "judge=#{run.judge_verdict || "nil"} security=#{run.security_verdict || "nil"}"
    prov_str = "provenance=#{run.provenance || "nil"}"
    stopped_str = if run.stopped_at, do: " stopped_at=#{run.stopped_at}", else: ""
    reason_str = if run.reason, do: " reason=#{inspect(run.reason)}", else: ""

    digest_line =
      "pipeline_run agent=#{agent_name} purpose=#{inspect(run.purpose)} outcome=#{run.outcome}#{stopped_str}#{reason_str} #{verdicts_str} #{prov_str}"

    append_opts = if run_log_path, do: [path: run_log_path], else: []
    AgentOS.RunLog.append_digest(digest_line, append_opts)
  end
end
