defmodule AgentOS.Pipeline.Rerun.Record do
  @moduledoc """
  A record of one user-triggered "Re-run checks" recovery run (spec 043).

  Persisted to the `check_reruns` StateStore keyed by `agent_name` (the latest re-run
  replaces the prior record — gating always uses the latest verdicts). `code_hash` ties
  the record to the exact code version that was examined (FR-003).
  """

  @type outcome :: :passed | :failed | :incomplete

  @type t :: %__MODULE__{
          run_id: String.t(),
          agent_name: String.t(),
          code_hash: String.t(),
          judge_verdict: atom() | nil,
          security_verdict: atom() | nil,
          outcome: outcome(),
          reason: String.t() | nil,
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil
        }

  @enforce_keys [:run_id, :agent_name, :outcome, :started_at]
  defstruct [
    :run_id,
    :agent_name,
    :code_hash,
    :judge_verdict,
    :security_verdict,
    :outcome,
    :reason,
    :started_at,
    :finished_at
  ]
end

defmodule AgentOS.Pipeline.Rerun do
  @moduledoc """
  Partial-pipeline "Re-run checks" recovery (spec 043).

  Re-runs ONLY the two safety checks — Stage 3 (blind compliance judge) and Stage 5
  (security review) — against an agent's EXISTING generated code and manifest, with no
  elicitation and no code regeneration. Fresh verdicts land (via the reused stages) in the
  `judge_results` / `security_review_results` StateStores keyed to the current `code_hash`,
  so a green re-run opens `AgentOS.Provisioner.deploy_gate/3` exactly as a fresh generation
  would.

  ### Recovery goes through the checks, never around them
  A re-run NEVER deploys, approves, records provenance, or runs the agent. A red or
  incomplete re-run leaves the agent blocked exactly as before, with the reason visible
  (FR-004, FR-005; Constitution XI — the deterministic gate stays the only firewall).

  ### Setup activity, not runtime spend
  Re-running checks is setup activity (like the original creation-time checks), so it must
  never be metered against the agent's runtime spend cap. `run/2` registers the run token
  with the broker under an UNCAPPED setup manifest (mirroring the orchestrator's
  `"orchestrator"` token); `Stage3.run/3` further re-registers under the agent with its own
  uncapped eval manifest, and `Stage5.review/4` meters on this token.

  ### Co-generation isolation preserved
  No re-classification and no code regeneration: `Stage3.generate/3` derives the test spec
  from the manifest + purpose + the agent's on-disk execution-mode sidecar only — never from
  the code.
  """

  require Logger

  alias AgentOS.Pipeline.{Stage3, Stage5, ProgressEvent, RunLock}
  alias AgentOS.Pipeline.Rerun.Record
  alias AgentOS.{Manifest, Provisioner, StateStore, InferenceBroker}

  @check_reruns_store "check_reruns"

  @doc """
  Pure eligibility check (no side effects). A re-run is offered only for a user-managed
  agent that has generated code, a loadable manifest, and checks that are NOT already
  green for the current code — a re-run is a recovery path, and re-examining an
  already-green agent is a paid no-op.

  Returns `:ok`, or
  `{:error, :system_agent | :code_missing | :manifest_missing | :checks_green}`.
  Opts: `:spec_dir` (agents tree, default `"agents"`), `:manifest_dir` (default `"manifests"`).
  """
  @spec eligible?(String.t(), keyword()) ::
          :ok | {:error, :system_agent | :code_missing | :manifest_missing | :checks_green}
  def eligible?(agent_name, opts \\ []) when is_binary(agent_name) do
    spec_dir = Keyword.get(opts, :spec_dir, "agents")
    manifest_dir = Keyword.get(opts, :manifest_dir, "manifests")
    main = Path.join([spec_dir, agent_name, "main.py"])
    models = Path.join([spec_dir, agent_name, "models.py"])
    manifest_path = Path.join(manifest_dir, "#{agent_name}.md")

    cond do
      AgentOS.AgentLifecycle.system_agent?(agent_name) ->
        {:error, :system_agent}

      not (File.exists?(main) and File.exists?(models)) ->
        {:error, :code_missing}

      match?({:error, _}, Manifest.load(manifest_path)) ->
        {:error, :manifest_missing}

      checks_green?(agent_name, opts) ->
        {:error, :checks_green}

      true ->
        :ok
    end
  end

  @doc """
  True when both verdicts already pass for the agent's CURRENT code — the deploy gate
  would open, so there is nothing for a re-run to recover.
  """
  @spec checks_green?(String.t(), keyword()) :: boolean()
  def checks_green?(agent_name, opts \\ []) do
    # :always_review forces the real verdict check regardless of configured mode
    # (in :dangerously_skip_review environments the gate is always :ok, which would
    # read as green and hide the recovery path exactly where it is being tested).
    AgentOS.Provisioner.deploy_gate(agent_name, :always_review, opts) == :ok and
      not AgentOS.AgentLifecycle.system_agent?(agent_name)
  end

  @doc """
  UI entry point. Synchronously checks eligibility and claims the one-run-per-agent lock
  (FR-009), then spawns a detached task that runs the checks and releases the lock. Returns
  `{:ok, run_id}` immediately so the caller observes live progress via the firehose, or
  `{:error, :system_agent | :code_missing | :manifest_missing | :busy}`.

  Test seam: `:runner_fn` `(agent_name, run_id, opts -> any)` replaces the detached spawn.
  """
  @spec start(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def start(agent_name, opts \\ []) when is_binary(agent_name) do
    # Config seam for callers that can't pass opts (the LiveView button): tests
    # inject :runner_fn here so a click never spawns a live-inference task.
    opts = Keyword.merge(Application.get_env(:agent_os, :rerun_default_opts, []), opts)

    with :ok <- eligible?(agent_name, opts),
         :ok <- RunLock.claim(agent_name) do
      run_id = Keyword.get(opts, :run_id) || "rerun_#{System.unique_integer([:positive])}"
      runner_fn = Keyword.get(opts, :runner_fn, &default_start_task/3)
      runner_fn.(agent_name, run_id, opts)
      {:ok, run_id}
    end
  end

  # Fire-and-forget under the pipeline task supervisor: the run survives the LiveView, and
  # the lock is released whether the run finishes or crashes.
  defp default_start_task(agent_name, run_id, opts) do
    task_opts = Keyword.put(opts, :run_id, run_id)

    Task.Supervisor.start_child(AgentOS.PipelineTaskSupervisor, fn ->
      try do
        run(agent_name, task_opts)
      after
        RunLock.release(agent_name)
      end
    end)

    :ok
  end

  @doc """
  Synchronous core: re-runs Stage 3 + Stage 5 against the agent's existing code and manifest,
  persists a `Record` to `check_reruns`, and returns `{:ok, record}` when both checks pass,
  else `{:error, record}`. Returns `{:error, reason}` (no record) only when the manifest or
  code cannot be loaded at all.

  Opts forwarded to the stages: `:provider_fn`, `:prices`, `:now`, `:model`, `:spec_dir`,
  `:manifest_dir`, `:run_token`, `:runner_fn` (Stage 3 agent-execution seam), `:run_id`.
  """
  @spec run(String.t(), keyword()) :: {:ok, Record.t()} | {:error, Record.t() | atom()}
  def run(agent_name, opts \\ []) when is_binary(agent_name) do
    manifest_dir = Keyword.get(opts, :manifest_dir, "manifests")
    spec_dir = Keyword.get(opts, :spec_dir, "agents")
    manifest_path = Path.join(manifest_dir, "#{agent_name}.md")

    with {:ok, manifest} <- Manifest.load(manifest_path),
         {:ok, code_files} <- load_code_files(agent_name, spec_dir) do
      do_run(agent_name, manifest, code_files, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # --- core ---

  defp do_run(agent_name, manifest, code_files, opts) do
    started_at = Keyword.get(opts, :now, DateTime.utc_now())
    run_id = Keyword.get(opts, :run_id) || "rerun_#{System.unique_integer([:positive])}"

    run_token =
      opts[:run_token] || "rerun_token_#{agent_name}_#{System.unique_integer([:positive])}"

    # Uncapped setup registration — a re-run must never be blocked by the agent's runtime
    # spend cap. Unregistered in the `after` no matter what.
    setup_manifest = %Manifest{
      purpose: "Agent OS Check Re-run",
      owner: "system",
      supervision: "autonomous",
      grants: [],
      spend: %Manifest.Spend{cap: 1_000_000_000, window: :daily, on_breach: :kill}
    }

    :ok = InferenceBroker.register(run_token, "rerun", setup_manifest)
    stage_opts = Keyword.put(opts, :run_token, run_token)

    try do
      judge_verdict = run_judge(agent_name, manifest, run_id, stage_opts)
      security_verdict = run_security(agent_name, manifest, code_files, run_id, stage_opts)

      record =
        build_record(agent_name, run_id, started_at, judge_verdict, security_verdict, stage_opts)

      emit(run_id, agent_name, :pipeline, record.outcome, record.reason)
      persist(agent_name, record)

      if record.outcome == :passed, do: {:ok, record}, else: {:error, record}
    after
      InferenceBroker.unregister(run_token)
    end
  end

  # Stage 3 (blind compliance judge). Returns the Verdict, or nil when the stage aborts
  # before producing one (crash/interruption) — that maps to an :incomplete outcome.
  defp run_judge(agent_name, manifest, run_id, opts) do
    emit(run_id, agent_name, :judge, :started)

    verdict =
      try do
        case Stage3.generate(agent_name, manifest, opts) do
          {:ok, _spec} ->
            {:ok, verdict} = Stage3.run(agent_name, manifest, opts)
            verdict

          {:error, reason} ->
            Logger.warning(
              "Rerun: judge spec synthesis failed for #{agent_name}: #{inspect(reason)}"
            )

            nil
        end
      rescue
        e ->
          Logger.error("Rerun: judge crashed for #{agent_name}: #{inspect(e)}")
          nil
      catch
        :exit, reason ->
          Logger.error("Rerun: judge exited for #{agent_name}: #{inspect(reason)}")
          nil
      end

    status = verdict && verdict.status
    emit(run_id, agent_name, :judge, stage_status(status), status)
    verdict
  end

  # Stage 5 (security review). Returns the Verdict, or nil on abort (→ :incomplete).
  defp run_security(agent_name, manifest, code_files, run_id, opts) do
    emit(run_id, agent_name, :security_review, :started)

    verdict =
      try do
        case Stage5.review(agent_name, manifest, code_files, opts) do
          {:ok, verdict} ->
            verdict

          {:error, reason} ->
            Logger.warning(
              "Rerun: security review failed to complete for #{agent_name}: #{inspect(reason)}"
            )

            nil
        end
      rescue
        e ->
          Logger.error("Rerun: security review crashed for #{agent_name}: #{inspect(e)}")
          nil
      catch
        :exit, reason ->
          Logger.error("Rerun: security review exited for #{agent_name}: #{inspect(reason)}")
          nil
      end

    status = verdict && verdict.status
    emit(run_id, agent_name, :security_review, stage_status(status), status)
    verdict
  end

  defp build_record(agent_name, run_id, started_at, judge_v, security_v, opts) do
    judge_status = judge_v && judge_v.status
    security_status = security_v && security_v.status

    outcome =
      cond do
        judge_status == :pass and security_status == :pass -> :passed
        is_nil(judge_status) or is_nil(security_status) -> :incomplete
        true -> :failed
      end

    %Record{
      run_id: run_id,
      agent_name: agent_name,
      code_hash: Provisioner.code_hash(agent_name, opts),
      judge_verdict: judge_status,
      security_verdict: security_status,
      outcome: outcome,
      reason: derive_reason(outcome, judge_v, security_v),
      started_at: started_at,
      finished_at: Keyword.get(opts, :now, DateTime.utc_now())
    }
  end

  # Human-readable reason for a non-passing outcome, for card display (FR-005).
  defp derive_reason(:passed, _judge, _security), do: nil

  defp derive_reason(:incomplete, judge, security) do
    cond do
      is_nil(judge) -> "The code check did not complete — you can re-run to try again."
      is_nil(security) -> "The security review did not complete — you can re-run to try again."
    end
  end

  defp derive_reason(:failed, judge, security) do
    [reason_for("code check", judge), reason_for("security review", security)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp reason_for(_label, %{status: :pass}), do: nil
  defp reason_for(_label, nil), do: nil

  defp reason_for(label, %{status: status, reasoning: reasoning}),
    do: "The #{label} did not pass (#{status}): #{reasoning}"

  # A verdict status maps to the stage's terminal ProgressEvent status: pass → finished,
  # anything else (fail/error/malfunction/nil) → failed.
  defp stage_status(:pass), do: :finished
  defp stage_status(_), do: :failed

  defp emit(run_id, agent_name, stage, status, detail \\ nil) do
    run_id
    |> ProgressEvent.new(agent_name, stage, status, detail)
    |> ProgressEvent.broadcast()
  end

  defp persist(agent_name, %Record{} = record) do
    StateStore.apply_action(@check_reruns_store, {:put, agent_name, record})
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Reads main.py + models.py from the agents tree into the map shape Stage 5 expects.
  defp load_code_files(agent_name, spec_dir) do
    agent_dir = Path.join(spec_dir, agent_name)
    main_path = Path.join(agent_dir, "main.py")
    models_path = Path.join(agent_dir, "models.py")

    case {File.read(main_path), File.read(models_path)} do
      {{:ok, main}, {:ok, models}} ->
        {:ok, %{"main.py" => main, "models.py" => models}}

      _ ->
        {:error, :code_missing}
    end
  end
end
