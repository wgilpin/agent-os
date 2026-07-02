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
  alias AgentOS.Effector
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
            agent_cmd: "python",
            agent_args: ["agents/discovery/main.py"],
            manifest_path: "manifests/discovery.md"
          }
      end

    manifest_path = Keyword.get(opts, :manifest_path, cfg.manifest_path)
    agent_name = Path.basename(manifest_path, ".md")

    review_mode =
      Keyword.get(opts, :review_mode) ||
        Application.get_env(:agent_os, :review_mode, :always_review)

    case AgentOS.Provisioner.deploy(manifest_path, review_mode, opts) do
      {:blocked, ref} ->
        run_log_path = Keyword.get(opts, :run_log_path, Path.join(["data", "run_log.md"]))
        trigger = Keyword.get(opts, :trigger, :timer)

        AgentOS.RunLog.append(
          %{
            status: :error,
            actions: 0,
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
            run_token = Base.encode16(:crypto.strong_rand_bytes(16))

            if GenServer.whereis(AgentOS.InferenceBroker) do
              AgentOS.InferenceBroker.register(run_token, agent_name, manifest)
            end

            original_run_token = System.get_env("RUN_TOKEN")
            original_inf_socket = System.get_env("INFERENCE_SOCKET")

            System.put_env("RUN_TOKEN", run_token)

            System.put_env(
              "INFERENCE_SOCKET",
              Path.expand(
                Application.get_env(:agent_os, :inference_uds_path, "data/inference.sock")
              )
            )

            opts_with_env =
              Keyword.update(
                opts,
                :env,
                %{"RUN_TOKEN" => run_token, "INFERENCE_SOCKET" => "/tmp/inference.sock"},
                fn existing_env ->
                  existing_env
                  |> Map.put("RUN_TOKEN", run_token)
                  |> Map.put("INFERENCE_SOCKET", "/tmp/inference.sock")
                end
              )

            {cmd, args} =
              if Keyword.has_key?(opts_with_env, :agent_cmd) and
                   Keyword.get(opts_with_env, :agent_cmd) != "docker" do
                {Keyword.get(opts_with_env, :agent_cmd), Keyword.get(opts_with_env, :agent_args)}
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

                sandbox = %AgentOS.Sandbox{
                  image: Keyword.get(opts_with_env, :image, "agent-discovery:dev"),
                  cidfile: cidfile,
                  network: Keyword.get(opts_with_env, :network, "none"),
                  memory_mb: Keyword.get(opts_with_env, :memory_mb, 128),
                  cpus: Keyword.get(opts_with_env, :cpus, "0.5"),
                  user: aligned_user,
                  env: Keyword.get(opts_with_env, :env, %{}),
                  entrypoint: Keyword.get(opts_with_env, :entrypoint),
                  cmd_args: Keyword.get(opts_with_env, :cmd_args),
                  mounts: [
                    {Path.expand(
                       Application.get_env(:agent_os, :inference_uds_path, "data/inference.sock")
                     ), "/tmp/inference.sock"}
                  ]
                }

                {"docker", AgentOS.Sandbox.build_argv(sandbox)}
              end

            res = execute_run(cmd, args, manifest, agent_name, opts_with_env)

            if original_run_token,
              do: System.put_env("RUN_TOKEN", original_run_token),
              else: System.delete_env("RUN_TOKEN")

            if original_inf_socket,
              do: System.put_env("INFERENCE_SOCKET", original_inf_socket),
              else: System.delete_env("INFERENCE_SOCKET")

            if GenServer.whereis(AgentOS.InferenceBroker) do
              AgentOS.InferenceBroker.unregister(run_token)
            end

            res
        end
    end
  end

  defp execute_run(cmd, args, manifest, agent_name, opts) do
    run_log_path = Keyword.get(opts, :run_log_path, Path.join(["data", "run_log.md"]))
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    bookmarks_path =
      Keyword.get(opts, :bookmarks_path) ||
        Application.get_env(:agent_os, :bookmarks_path, "data/bookmarks.json")

    trigger = Keyword.get(opts, :trigger, :timer)

    {items, dropped_count} =
      if cmd == "docker" do
        case Keyword.get(opts, :items) do
          nil -> AgentOS.Provisioner.load_and_sanitize_bookmarks(bookmarks_path)
          explicit_items -> {explicit_items, 0}
        end
      else
        {[], 0}
      end

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

      dispatch_on_breach(
        manifest.spend.on_breach,
        run_log_path,
        trigger,
        length(items) + dropped_count,
        [],
        [],
        [],
        [:inference],
        dropped_count
      )
    else
      with snapshot <- StateStore.snapshot("roster_trust"),
           input_json <-
             (if cmd == "docker" do
                Jason.encode!(build_payload(snapshot, items, Keyword.get(opts, :trigger_input)))
              else
                Jason.encode!(%{"roster" => snapshot.records || []})
              end),
           {:ok, stdout} <- PortRunner.run(input_json, cmd, args, timeout_ms: timeout_ms),
           %{"actions" => actions} <- Jason.decode!(stdout) do
        # Re-fetch spend ledger in case inference during the run pushed us over cap
        spend_ledger = StateStore.snapshot("spend_ledger")
        raw_entry = Map.get(spend_ledger, agent_name, %{spent: 0, window_start: now})
        agent_entry = AgentOS.SpendLedger.current_entry(raw_entry, now, manifest.spend.window)
        spent = agent_entry.spent

        if spent >= manifest.spend.cap do
          Logger.warning(
            "Inference mid-run breach: agent '#{agent_name}' spent (#{spent}) >= cap (#{manifest.spend.cap})"
          )

          dispatch_on_breach(
            manifest.spend.on_breach,
            run_log_path,
            trigger,
            length(items) + dropped_count,
            actions,
            [],
            [],
            [:inference],
            dropped_count
          )
        else
          registry = AgentOS.Connector.registry()

          {approved, parked, rejected, breached} =
            AgentOS.Gate.partition_batch(actions, manifest, registry, %{spent: spent})

          items_in = length(items) + dropped_count

          cond do
            breached != [] ->
              dispatch_on_breach(
                manifest.spend.on_breach,
                run_log_path,
                trigger,
                items_in,
                actions,
                rejected,
                parked,
                breached,
                dropped_count
              )

            true ->
              Effector.act_all(approved)

              total_approved_cost =
                Enum.reduce(approved, 0, fn %{action: action}, acc ->
                  acc + get_cost(action.type, registry)
                end)

              if total_approved_cost > 0 do
                new_spent = spent + total_approved_cost
                updated_entry = Map.put(agent_entry, :spent, new_spent)
                StateStore.apply_action("spend_ledger", {:put, agent_name, updated_entry})
              end

              if parked != [] do
                pending_store = StateStore.snapshot("pending_approvals")
                approvals = Map.get(pending_store, :approvals, %{})

                updated_approvals =
                  Enum.reduce(parked, approvals, fn %{action: act, grant: grt}, acc ->
                    ref = "ref_#{System.unique_integer([:positive])}"
                    Map.put(acc, ref, %{ref: ref, action: act, grant: grt})
                  end)

                StateStore.apply_action(
                  "pending_approvals",
                  {:put, :approvals, updated_approvals}
                )
              end

              reasons = Enum.map(rejected, fn {_raw, reason} -> reason end) |> Enum.uniq()

              RunLog.append(
                %{
                  status: :ok,
                  actions: length(approved),
                  trigger: trigger,
                  exit_code: 0,
                  items_in: items_in,
                  items_dropped: dropped_count + length(rejected) + length(parked),
                  approved_count: length(approved),
                  rejected_count: length(rejected),
                  parked_count: length(parked),
                  breached_count: 0,
                  gate_reasons: reasons,
                  note: "run complete"
                },
                path: run_log_path
              )

              :ok
          end
        end
      else
        {:error, reason} ->
          {exit_code, failure_cause} =
            case reason do
              {:exit_status, 137} -> {137, "oom"}
              {:exit_status, code} -> {code, "crash"}
              :timeout -> {nil, "timeout"}
              _other -> {nil, "other"}
            end

          items_in = length(items) + dropped_count

          RunLog.append(
            %{
              status: :error,
              actions: 0,
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
          items_in = length(items) + dropped_count

          RunLog.append(
            %{
              status: :error,
              actions: 0,
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
      "state" => %{"records" => snapshot.records || []},
      "items" => items
    }

    if is_nil(trigger_input) do
      payload
    else
      Map.put(payload, "trigger_input", trigger_input)
    end
  end

  defp get_cost(type, registry) do
    case Map.get(registry, type) do
      nil -> 0
      conn -> Map.get(conn, :cost, 0)
    end
  end

  defp dispatch_on_breach(
         :kill,
         run_log_path,
         trigger,
         items_in,
         actions,
         rejected,
         parked,
         breached,
         dropped_count
       ) do
    RunLog.append(
      %{
        status: :killed,
        actions: 0,
        trigger: trigger,
        exit_code: 0,
        failure_cause: :spend_breach,
        items_in: items_in,
        items_dropped: dropped_count + length(actions),
        approved_count: 0,
        rejected_count: length(rejected),
        parked_count: length(parked),
        breached_count: length(breached),
        gate_reasons: [:spend_breach],
        note: "killed: :spend_breach"
      },
      path: run_log_path
    )

    {:killed, :spend_breach}
  end
end
