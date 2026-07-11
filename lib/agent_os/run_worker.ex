defmodule AgentOS.RunWorker do
  @moduledoc """
  Implements the end-to-end enforcement-spine run pipeline:
  provision → snapshot → port → output check → act-on-behalf → run-log.

  Exposes `run_once/1` which returns `:ok | {:error, reason}` without raising,
  and a supervised `start_link/1` wrapper which raises on error to drive transient
  restart-once supervision.

  ### Boundary Invariant
  The manifest is gate-only (substrate-only) and never crosses the port boundary
  into the agent container. The agent-bound payload is exactly `{state, items}`
  plus the published action schema; it never carries envelope data (grants, spend, etc.).
  Enforced by `test/agent_os/boundary_test.exs` (FR-007, VR-007).
  """

  require Logger

  alias AgentOS.Provisioner
  alias AgentOS.Manifest
  alias AgentOS.StateStore
  alias AgentOS.PortRunner
  alias AgentOS.OutcomeRecord
  alias AgentOS.RunLog

  @doc """
  Custom child specification for mounting in supervision trees as a transient worker.
  Allows supervisors (like Task.Supervisor or standard Supervisors) to understand how
  to start, identify, and restart the RunWorker process.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # :transient means the process is restarted only if it exits abnormally (non-zero or raised error).
      restart: :transient
    }
  end

  @doc """
  Starts the task as a supervised process.
  Invoked by the supervisor. Uses MFA (Module, Function, Arguments) to spawn the task.
  """
  def start_link(opts \\ []) do
    # Task.start_link/3 spawns a Task process linked to the caller.
    Task.start_link(__MODULE__, :run_and_raise, [opts])
  end

  @doc """
  Internal helper invoked by Task.start_link to raise on error.
  This translates execution failures into process crashes, which allows
  OTP supervision to detect the abnormal exit and trigger restarts.
  """
  def run_and_raise(opts) do
    case run_once(opts) do
      # Normal exit: exits with :ok which Erlang translates to :normal exit status.
      :ok ->
        :ok

      # Intentional stop: exits with :ok which Erlang translates to :normal exit status.
      {:killed, _reason} ->
        :ok

      # Abnormal exit: raises an exception, causing the process to fail.
      {:error, reason} ->
        raise "RunWorker failed: #{inspect(reason)}"
    end
  end

  @doc """
  Executes the full pipeline once.
  Does not raise; returns status tuples.

  ## Parameters
    - `opts`: Keyword list of configuration overrides.
  """
  @spec run_once(keyword()) :: :ok | {:killed, :spend_breach} | {:error, any()}
  def run_once(opts \\ []) do
    cfg =
      try do
        Provisioner.agent_config()
      rescue
        _ ->
          %{
            agent_cmd: python_bin(),
            agent_args: ["agents/discovery/main.py"],
            manifest_path: "test/fixtures/manifests/discovery.md"
          }
      end

    # Dispatchers (TriggerGateway, TriggerArming, AgentLifecycle.run_now) identify the
    # target by :agent; direct callers may pass :manifest_path. With neither, the legacy
    # config agent runs.
    manifest_path =
      Keyword.get(opts, :manifest_path) ||
        agent_manifest_path(Keyword.get(opts, :agent)) ||
        cfg.manifest_path

    agent_name = Path.basename(manifest_path, ".md")
    config_agent = Path.basename(cfg.manifest_path, ".md")

    # Both config and generated agents run through the one container sandbox path
    # (FR-004/FR-005). There is NO direct host-interpreter dispatch for generated agents:
    # the bypass that ran them as a bare `.venv/bin/python` child has been removed. An
    # explicit :agent_cmd (tests, harnesses) still wins at the dispatch guard below (FR-006).
    config_agent? = agent_name == config_agent

    review_mode =
      Keyword.get(opts, :review_mode) ||
        Application.get_env(:agent_os, :review_mode, :always_review)

    case AgentOS.Provisioner.deploy(manifest_path, review_mode, opts) do
      {:blocked, ref} ->
        run_log_path = Keyword.get(opts, :run_log_path, RunLog.default_path())
        trigger = Keyword.get(opts, :trigger, :timer)

        # A run parked on human approval is not a failure: it gets its own
        # :blocked status so the UI can render it as "waiting for you", not ERROR.
        AgentOS.RunLog.append(
          %{
            status: :blocked,
            actions: 0,
            agent: agent_name,
            trigger: trigger,
            note: "deploy blocked: ref=#{ref}"
          },
          path: run_log_path
        )

        {:error, {:deploy_blocked, ref}}

      _ ->
        case Manifest.load(manifest_path) do
          {:error, reason} ->
            {:error, reason}

          {:ok, manifest} ->
            # Run token identifies this invocation across the broker, capability rail,
            # and action transcript. Injectable via opts so tests can pre-seed the
            # transcript deterministically; a fresh random token otherwise.
            run_token =
              Keyword.get(opts, :run_token) || Base.encode16(:crypto.strong_rand_bytes(16))

            if GenServer.whereis(AgentOS.InferenceBroker) do
              effective_model = Application.get_env(:agent_os, :agent_runtime_model)

              AgentOS.InferenceBroker.register(
                run_token,
                agent_name,
                manifest,
                :live,
                effective_model
              )
            end

            original_run_token = System.get_env("RUN_TOKEN")
            original_inf_socket = System.get_env("INFERENCE_SOCKET")
            original_agent_model = System.get_env("AGENT_MODEL")

            System.put_env("RUN_TOKEN", run_token)
            effective_model = Application.get_env(:agent_os, :agent_runtime_model)
            if effective_model, do: System.put_env("AGENT_MODEL", effective_model)

            System.put_env(
              "INFERENCE_SOCKET",
              Path.expand(
                Application.get_env(:agent_os, :inference_uds_path, "data/inference.sock")
              )
            )

            # The socket path the agent process sees inside its container: /tmp/inference.sock in
            # host-bind mode, or the in-volume path (identical both sides) in shared-volume mode.
            container_inf_socket = AgentOS.InferenceTopology.container_socket_path()

            opts_with_env =
              Keyword.update(
                opts,
                :env,
                %{"RUN_TOKEN" => run_token, "INFERENCE_SOCKET" => container_inf_socket}
                |> (fn env ->
                      if effective_model,
                        do: Map.put(env, "AGENT_MODEL", effective_model),
                        else: env
                    end).(),
                fn existing_env ->
                  existing_env
                  |> Map.put("RUN_TOKEN", run_token)
                  |> Map.put("INFERENCE_SOCKET", container_inf_socket)
                  |> (fn env ->
                        if effective_model,
                          do: Map.put(env, "AGENT_MODEL", effective_model),
                          else: env
                      end).()
                end
              )

            {cmd, args, dispatch} =
              if Keyword.has_key?(opts_with_env, :agent_cmd) and
                   Keyword.get(opts_with_env, :agent_cmd) != "docker" do
                # Explicit command override (tests, harnesses): honoured unchanged (FR-006);
                # no sandbox, no pre-flight.
                {Keyword.get(opts_with_env, :agent_cmd), Keyword.get(opts_with_env, :agent_args),
                 nil}
              else
                cidfile =
                  Keyword.get(opts_with_env, :cidfile) ||
                    Path.join(
                      System.tmp_dir!(),
                      "cidfile_#{System.unique_integer([:positive])}.txt"
                    )

                # Retrieve the configured dedicated inference GID and align user option
                configured_gid = AgentOS.InferenceBroker.get_configured_gid()
                user_opt = Keyword.get(opts_with_env, :user, "1000:1000")

                aligned_user =
                  case String.split(user_opt, ":") do
                    [uid] -> "#{uid}:#{configured_gid}"
                    [uid, _gid] -> "#{uid}:#{configured_gid}"
                    _ -> "1000:#{configured_gid}"
                  end

                # Config and generated agents share this struct; dispatch_spec/3 supplies the
                # only differences — image, entrypoint, command, and the read-only code mount
                # for generated bodies (FR-002/FR-003/FR-004).
                spec = dispatch_spec(agent_name, config_agent, opts_with_env)

                sandbox = %AgentOS.Sandbox{
                  image: spec.image,
                  cidfile: cidfile,
                  network: Keyword.get(opts_with_env, :network, "none"),
                  memory_mb: Keyword.get(opts_with_env, :memory_mb, 128),
                  cpus: Keyword.get(opts_with_env, :cpus, "0.5"),
                  user: aligned_user,
                  env: Keyword.get(opts_with_env, :env, %{}),
                  entrypoint: spec.entrypoint,
                  cmd_args: spec.cmd_args,
                  mounts: spec.mounts
                }

                {"docker", AgentOS.Sandbox.build_argv(sandbox), spec}
              end

            res =
              execute_run(
                cmd,
                args,
                manifest,
                agent_name,
                run_token,
                config_agent?,
                dispatch,
                opts_with_env
              )

            if original_run_token,
              do: System.put_env("RUN_TOKEN", original_run_token),
              else: System.delete_env("RUN_TOKEN")

            if original_inf_socket,
              do: System.put_env("INFERENCE_SOCKET", original_inf_socket),
              else: System.delete_env("INFERENCE_SOCKET")

            if original_agent_model,
              do: System.put_env("AGENT_MODEL", original_agent_model),
              else: System.delete_env("AGENT_MODEL")

            if GenServer.whereis(AgentOS.InferenceBroker) do
              AgentOS.InferenceBroker.unregister(run_token)
            end

            res
        end
    end
  end

  # The manifest for a dispatched :agent — the deployment record's path when registered,
  # else the conventional location. Tolerates an absent registry (minimal test trees).
  # Generated agents import venv-installed packages (e.g. pydantic), so they run
  # under the project venv interpreter, not whatever bare `python` is on PATH —
  # the same resolution the elicitor and the judge harness use.
  defp python_bin, do: System.get_env("PYTHON_BIN") || ".venv/bin/python"

  @doc """
  Builds the per-agent container dispatch parameters — image, entrypoint, command, mounts,
  and the code directory to mount — for the one shared sandbox path (FR-004).

  Config and generated agents differ ONLY here: the config agent runs its own code-baked
  image (no code mount, baked entrypoint), while a generated agent runs the generic
  `generated_agent_image` with its body bind-mounted read-only at `/app/agents/<name>`
  (FR-002/FR-003) and the interpreter invoked against that mounted path. The inference UDS
  is the sole writable host mount for both (FR-007). Explicit `:image`, `:entrypoint`, and
  `:cmd_args` opts (tests) still override. Pure and Docker-free so it is unit-testable.
  """
  @spec dispatch_spec(binary(), binary(), keyword()) :: %{
          image: binary(),
          entrypoint: binary() | nil,
          cmd_args: [binary()] | nil,
          mounts: [{binary(), binary()}],
          code_dir: binary() | nil
        }
  def dispatch_spec(agent_name, config_agent, opts \\ []) do
    # Inference channel mount source depends on the socket topology (feature 045):
    #   host-bind    -> bind the host socket FILE at the fixed container target
    #                   /tmp/inference.sock (current behaviour on Linux hosts / unit tests).
    #   shared-volume -> mount the NAMED VOLUME at its identical path in both containers, so a
    #                   macOS-VM agent shares the broker's listening endpoint (same kernel), not
    #                   just a bind-shared file node. sandbox.ex validates this is the sole
    #                   writable mount.
    inference_mount =
      case AgentOS.InferenceTopology.mode() do
        :host_bind ->
          {Path.expand(
             Application.get_env(:agent_os, :inference_uds_path, "data/inference.sock")
           ), "/tmp/inference.sock"}

        :shared_volume ->
          {AgentOS.InferenceTopology.volume_name(), AgentOS.InferenceTopology.volume_path()}
      end

    if agent_name == config_agent do
      %{
        image:
          Keyword.get(opts, :image) ||
            Application.get_env(:agent_os, :agent_image, "agent-discovery:dev"),
        entrypoint: Keyword.get(opts, :entrypoint),
        cmd_args: Keyword.get(opts, :cmd_args),
        mounts: [inference_mount],
        code_dir: nil
      }
    else
      # Generated body: mounted read-only; sandbox.ex enforces the ":ro" suffix and the
      # inference-UDS exception, so this is the only place the code path is named.
      code_dir = Path.expand(Path.join(["agents", agent_name]))

      %{
        image:
          Keyword.get(opts, :image) ||
            Application.get_env(:agent_os, :generated_agent_image, "agent-generated:dev"),
        entrypoint: Keyword.get(opts, :entrypoint) || "/app/.venv/bin/python",
        cmd_args: Keyword.get(opts, :cmd_args) || ["/app/agents/#{agent_name}/main.py"],
        mounts: [inference_mount, {code_dir, "/app/agents/#{agent_name}:ro"}],
        code_dir: code_dir
      }
    end
  end

  defp agent_manifest_path(nil), do: nil

  defp agent_manifest_path(agent) when is_binary(agent) do
    case AgentOS.DeploymentRegistry.get(agent) do
      %{manifest_path: path} when is_binary(path) -> path
      _ -> Path.join("manifests", agent <> ".md")
    end
  rescue
    _ -> Path.join("manifests", agent <> ".md")
  catch
    :exit, _ -> Path.join("manifests", agent <> ".md")
  end

  # Pre-flights the container runtime, then runs the pipeline. Missing images, an
  # unavailable daemon, or an unmountable code directory fail loudly with a diagnosable
  # cause (Constitution VI, FR-009) — never silently and never by falling back to a host run
  # (the fallback branch no longer exists).
  defp execute_run(cmd, args, manifest, agent_name, run_token, config_agent?, dispatch, opts) do
    run_log_path = Keyword.get(opts, :run_log_path, RunLog.default_path())
    trigger = Keyword.get(opts, :trigger, :timer)

    case preflight_docker(cmd, dispatch, agent_name, run_log_path, trigger) do
      {:error, _reason} = err ->
        err

      :ok ->
        do_execute_run(cmd, args, manifest, agent_name, run_token, config_agent?, opts)
    end
  end

  # Sandbox dispatch: verify the code mount, then the runtime image/daemon. Only the
  # docker path (a non-nil dispatch spec) is pre-flighted; explicit overrides are not.
  defp preflight_docker(
         "docker",
         %{image: image, code_dir: code_dir},
         agent_name,
         run_log_path,
         trigger
       ) do
    cond do
      not is_nil(code_dir) and not File.dir?(code_dir) ->
        preflight_fail(
          "code_unmountable",
          :code_unmountable,
          "agent code directory is absent or unreadable: #{code_dir}",
          agent_name,
          run_log_path,
          trigger
        )

      true ->
        preflight_image(image, agent_name, run_log_path, trigger)
    end
  end

  # Non-docker dispatch (explicit override) has no pre-flight.
  defp preflight_docker(_cmd, _dispatch, _agent_name, _run_log_path, _trigger), do: :ok

  # `docker image inspect` distinguishes a missing image from an unavailable daemon so
  # each fails with its own diagnosable cause (FR-009).
  defp preflight_image(image, agent_name, run_log_path, trigger) do
    case System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, _code} ->
        {cause_str, cause} = classify_image_error(out)

        preflight_fail(
          cause_str,
          cause,
          "docker image inspect failed for #{image}: #{String.trim(out)}",
          agent_name,
          run_log_path,
          trigger
        )
    end
  end

  defp classify_image_error(out) do
    if out =~ "Cannot connect to the Docker daemon",
      do: {"runtime_unavailable", :runtime_unavailable},
      else: {"image_unavailable", :image_unavailable}
  end

  # Logs loudly and records a diagnosable failure_cause in the run-log (FR-009).
  defp preflight_fail(cause_str, cause, message, agent_name, run_log_path, trigger) do
    Logger.error("dispatch pre-flight failed for '#{agent_name}': #{message}")

    RunLog.append(
      %{
        status: :error,
        actions: 0,
        agent: agent_name,
        trigger: trigger,
        failure_cause: cause_str,
        note: "dispatch pre-flight failed: #{message}"
      },
      path: run_log_path
    )

    {:error, cause}
  end

  defp do_execute_run(cmd, args, manifest, agent_name, run_token, config_agent?, opts) do
    run_log_path = Keyword.get(opts, :run_log_path, RunLog.default_path())
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    bookmarks_path =
      Keyword.get(opts, :bookmarks_path) ||
        Application.get_env(:agent_os, :bookmarks_path, "data/bookmarks.json")

    trigger = Keyword.get(opts, :trigger, :timer)

    # Bookmarks + the full {state, items} payload are the config/discovery agent's real
    # sandboxed-run input ONLY. Generated agents (docker or override) and any test override
    # get the minimal {roster}+trigger_input payload — this keys on config-agent identity,
    # not merely on cmd == "docker" (which generated agents now also use).
    config_docker? = config_agent? and cmd == "docker"

    {items, dropped_count} =
      if config_docker? do
        case Keyword.get(opts, :items) do
          nil -> AgentOS.Provisioner.load_and_sanitize_bookmarks(bookmarks_path)
          explicit_items -> {explicit_items, 0}
        end
      else
        {[], 0}
      end

    items_in = length(items) + dropped_count

    now = Keyword.get(opts, :now, DateTime.utc_now())
    spend_ledger = StateStore.snapshot("spend_ledger")
    raw_entry = Map.get(spend_ledger, agent_name, %{spent: 0, window_start: now})
    agent_entry = AgentOS.SpendLedger.current_entry(raw_entry, now, manifest.spend.window)

    if agent_entry != raw_entry do
      StateStore.apply_action("spend_ledger", {:put, agent_name, agent_entry})
    end

    if agent_entry.spent >= manifest.spend.cap do
      Logger.warning(
        "Inference pre-check breach: agent '#{agent_name}' spent (#{agent_entry.spent}) >= cap (#{manifest.spend.cap})"
      )

      # Agent never ran; no effects to report — an empty tally.
      dispatch_on_breach(
        manifest.spend.on_breach,
        agent_name,
        run_log_path,
        trigger,
        items_in,
        dropped_count,
        %{}
      )
    else
      with snapshot <- StateStore.snapshot("roster_trust"),
           input_json <-
             (if config_docker? do
                Jason.encode!(build_payload(snapshot, items, Keyword.get(opts, :trigger_input)))
              else
                # Non-docker (generated-agent / test) runs still receive their trigger
                # payload — a message-triggered agent is useless without its message.
                base = %{"roster" => roster_records(snapshot)}

                case Keyword.get(opts, :trigger_input) do
                  nil -> Jason.encode!(base)
                  trigger_input -> Jason.encode!(Map.put(base, "trigger_input", trigger_input))
                end
              end),
           {:ok, stdout} <- PortRunner.run(input_json, cmd, args, timeout_ms: timeout_ms),
           {:ok, _outcome} <- OutcomeRecord.parse(stdout) do
        # The agent acted only through the broker tool-call channel during inference; the
        # capability rail already gated, executed, parked, and recorded every effect to the
        # ActionTranscript, and the broker already charged the spend ledger. run_worker is a
        # reader: it derives the run-log tally from the transcript and never re-executes.
        spend_ledger = StateStore.snapshot("spend_ledger")
        raw_entry = Map.get(spend_ledger, agent_name, %{spent: 0, window_start: now})
        agent_entry = AgentOS.SpendLedger.current_entry(raw_entry, now, manifest.spend.window)
        spent = agent_entry.spent

        tally = tally_transcript(run_token)

        if spent >= manifest.spend.cap do
          Logger.warning(
            "Inference mid-run breach: agent '#{agent_name}' spent (#{spent}) >= cap (#{manifest.spend.cap})"
          )

          dispatch_on_breach(
            manifest.spend.on_breach,
            agent_name,
            run_log_path,
            trigger,
            items_in,
            dropped_count,
            tally
          )
        else
          RunLog.append(
            %{
              status: :ok,
              actions: tally.approved,
              agent: agent_name,
              trigger: trigger,
              exit_code: 0,
              items_in: items_in,
              items_dropped: dropped_count + tally.rejected + tally.parked,
              approved_count: tally.approved,
              rejected_count: tally.rejected,
              parked_count: tally.parked,
              breached_count: 0,
              gate_reasons: tally.gate_reasons,
              note: "run complete"
            },
            path: run_log_path
          )

          :ok
        end
      else
        {:error, :malformed} ->
          # Clean cutover: stdout that is not a terminal outcome record — including the
          # retired {"actions":[…]} shape — is malformed. Any effects the rail already
          # recorded to the transcript stand; we do not undo them.
          RunLog.append(
            %{
              status: :error,
              actions: 0,
              agent: agent_name,
              trigger: trigger,
              failure_cause: "malformed_outcome",
              items_in: items_in,
              items_dropped: dropped_count,
              note:
                "malformed outcome record on stdout (retired {\"actions\"} protocol not accepted)"
            },
            path: run_log_path
          )

          {:error, :malformed_outcome}

        {:error, reason} ->
          {exit_code, failure_cause} =
            case reason do
              {:exit_status, 137} -> {137, "oom"}
              {:exit_status, code} -> {code, "crash"}
              :timeout -> {nil, "timeout"}
              _other -> {nil, "other"}
            end

          RunLog.append(
            %{
              status: :error,
              actions: 0,
              agent: agent_name,
              trigger: trigger,
              exit_code: exit_code,
              failure_cause: failure_cause,
              items_in: items_in,
              items_dropped: dropped_count,
              note: "run failed: #{inspect(reason)}"
            },
            path: run_log_path
          )

          {:error, reason}

        other ->
          RunLog.append(
            %{
              status: :error,
              actions: 0,
              agent: agent_name,
              trigger: trigger,
              failure_cause: "unexpected_stage_result",
              items_in: items_in,
              items_dropped: dropped_count,
              note: "unexpected pipeline stage result: #{inspect(other)}"
            },
            path: run_log_path
          )

          {:error, other}
      end
    end
  end

  # Reads the action transcript for this run token and reduces it to run-log counts.
  # Granted/parked/rejected entries were written by the capability rail during inference.
  defp tally_transcript(run_token) do
    entries = AgentOS.ActionTranscript.read(run_token).entries

    rejected_entries = Enum.filter(entries, &(&1.kind == :rejected))

    reasons =
      rejected_entries
      |> Enum.map(& &1.reason_code)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      approved: Enum.count(entries, &(&1.kind == :granted)),
      parked: Enum.count(entries, &(&1.kind == :parked)),
      rejected: length(rejected_entries),
      gate_reasons: reasons
    }
  end

  @doc """
  Builds the payload that will cross the boundary into the agent container.
  Contains exactly the state snapshot records and the sanitized bookmark items.
  """
  @spec build_payload(map(), list()) :: map()
  def build_payload(snapshot, items) do
    build_payload(snapshot, items, nil)
  end

  @spec build_payload(map(), list(), term()) :: map()
  def build_payload(snapshot, items, trigger_input) do
    payload = %{
      "state" => %{"records" => roster_records(snapshot)},
      "items" => items
    }

    if is_nil(trigger_input) do
      payload
    else
      Map.put(payload, "trigger_input", trigger_input)
    end
  end

  # Reads the roster list tolerantly: fresh stores key it with the atom
  # :records, while a store hydrated from a legacy on-disk DB uses "records".
  defp roster_records(snapshot) do
    Map.get(snapshot, :records) || Map.get(snapshot, "records") || []
  end

  # Logs a spend-breach run and returns the killed sentinel. Effect counts come from the
  # transcript tally (empty on a pre-run breach where the agent never executed).
  defp dispatch_on_breach(
         :kill,
         agent_name,
         run_log_path,
         trigger,
         items_in,
         dropped_count,
         tally
       ) do
    rejected = Map.get(tally, :rejected, 0)
    parked = Map.get(tally, :parked, 0)

    RunLog.append(
      %{
        status: :killed,
        actions: 0,
        agent: agent_name,
        trigger: trigger,
        exit_code: 0,
        failure_cause: :spend_breach,
        items_in: items_in,
        items_dropped: dropped_count + rejected + parked,
        approved_count: Map.get(tally, :approved, 0),
        rejected_count: rejected,
        parked_count: parked,
        breached_count: 1,
        gate_reasons: [:spend_breach],
        note: "killed: :spend_breach"
      },
      path: run_log_path
    )

    {:killed, :spend_breach}
  end
end
