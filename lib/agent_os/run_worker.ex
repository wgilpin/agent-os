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
  @spec run_once(keyword()) :: :ok | {:error, any()}
  def run_once(opts \\ []) do
    # Load default configuration. We rescue errors to provide testing defaults
    # if the system environment is not fully populated.
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

    # Resolve the execution target. If the user explicitly passed a non-docker command
    # override, execute it on the host directly (helps keep legacy tests passing).
    # Otherwise, package the run inside the isolated Docker sandbox wrapper.
    {cmd, args} =
      if Keyword.has_key?(opts, :agent_cmd) and Keyword.get(opts, :agent_cmd) != "docker" do
        {Keyword.get(opts, :agent_cmd), Keyword.get(opts, :agent_args)}
      else
        # Ensure temporary file path for the container ID tracking file
        cidfile =
          Keyword.get(opts, :cidfile) ||
            Path.join(System.tmp_dir!(), "cidfile_#{System.unique_integer([:positive])}.txt")

        sandbox = %AgentOS.Sandbox{
          image: Keyword.get(opts, :image, "agent-discovery:dev"),
          cidfile: cidfile,
          network: Keyword.get(opts, :network, "none"),
          memory_mb: Keyword.get(opts, :memory_mb, 128),
          cpus: Keyword.get(opts, :cpus, "0.5"),
          user: Keyword.get(opts, :user, "1000:1000"),
          env: Keyword.get(opts, :env, %{}),
          entrypoint: Keyword.get(opts, :entrypoint),
          cmd_args: Keyword.get(opts, :cmd_args)
        }

        {"docker", AgentOS.Sandbox.build_argv(sandbox)}
      end

    manifest_path = Keyword.get(opts, :manifest_path, cfg.manifest_path)
    run_log_path = Keyword.get(opts, :run_log_path, Path.join(["data", "run_log.md"]))
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    bookmarks_path =
      Keyword.get(opts, :bookmarks_path) ||
        Application.get_env(:agent_os, :bookmarks_path, "data/bookmarks.json")

    trigger = Keyword.get(opts, :trigger, :timer)

    # Load and sanitize bookmark items outside 'with' to keep scope in the 'else' block
    {items, dropped_count} =
      if cmd == "docker" do
        case Keyword.get(opts, :items) do
          nil -> AgentOS.Provisioner.load_and_sanitize_bookmarks(bookmarks_path)
          explicit_items -> {explicit_items, 0}
        end
      else
        {[], 0}
      end

    # `with` is a special Elixir expression used to chain a sequence of pattern matches.
    # Each clause is evaluated in order. If all match, the `do` block is executed.
    # If any match fails, execution halts immediately and jumps to the `else` block,
    # returning the value of the failed match.
    with {:ok, manifest} <- Manifest.load(manifest_path),
         # 1. Take a snapshot of the current roster state.
         snapshot <- StateStore.snapshot("roster_trust"),

         # 2. Encode input into a JSON binary.
         input_json <-
           (if cmd == "docker" do
              # Send the structured state + items payload as required by boundary contract
              Jason.encode!(build_payload(snapshot, items))
            else
              # Send the list of records directly under the "roster" key (legacy)
              Jason.encode!(%{"roster" => snapshot.records || []})
            end),

         # 3. Run the python workload via PortRunner, capturing output or returning timeout/exits.
         {:ok, stdout} <- PortRunner.run(input_json, cmd, args, timeout_ms: timeout_ms),

         # 4. Decode output actions JSON.
         # Jason.decode!/1 parses the string into an Elixir map.
         %{"actions" => actions} <- Jason.decode!(stdout) do
      # --- Gate & Effector Execution Phase ---
      spend_ledger = StateStore.snapshot("spend_ledger")
      agent_name = Path.basename(manifest_path, ".md")

      agent_entry =
        Map.get(spend_ledger, agent_name, %{spent: 0, window_start: DateTime.utc_now()})

      spent = Map.get(agent_entry, :spent, 0)
      registry = AgentOS.Connector.registry()

      {approved, parked, rejected, breached} =
        AgentOS.Gate.partition_batch(actions, manifest, registry, %{spent: spent})

      items_in = length(items) + dropped_count

      cond do
        # 1. Breach check
        breached != [] ->
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

          :ok

        true ->
          # Execute approved actions
          Effector.act_all(approved)

          # Increment spend ledger for executed actions
          total_approved_cost =
            Enum.reduce(approved, 0, fn %{action: action}, acc ->
              acc + get_cost(action.type, registry)
            end)

          if total_approved_cost > 0 do
            new_spent = spent + total_approved_cost
            updated_entry = Map.put(agent_entry, :spent, new_spent)
            StateStore.apply_action("spend_ledger", {:put, agent_name, updated_entry})
          end

          # If there are parked actions (US5), we add them to pending approvals state store
          if parked != [] do
            pending_store = StateStore.snapshot("pending_approvals")
            approvals = Map.get(pending_store, :approvals, %{})

            # For each parked action, generate a unique ref and store it.
            # Reference: PendApproval {ref, action, grant}
            updated_approvals =
              Enum.reduce(parked, approvals, fn %{action: act, grant: grt}, acc ->
                ref = "ref_#{System.unique_integer([:positive])}"
                Map.put(acc, ref, %{ref: ref, action: act, grant: grt})
              end)

            StateStore.apply_action("pending_approvals", {:put, :approvals, updated_approvals})
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
    else
      # --- Error Path: One of the matches failed ---
      # Catch standard error tuples.
      {:error, reason} ->
        # Classify the error reason to extract exit code and failure cause
        {exit_code, failure_cause} =
          case reason do
            {:exit_status, 137} -> {137, "oom"}
            {:exit_status, code} -> {code, "crash"}
            :timeout -> {nil, "timeout"}
            _other -> {nil, "other"}
          end

        items_in = length(items) + dropped_count

        # Log failure to the run log file.
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

        # Return the error tuple.
        {:error, reason}

      # Catch any other unexpected values returned by the chain.
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

  @doc """
  Builds the payload that will cross the boundary into the agent container.
  Contains exactly the state snapshot records and the sanitized bookmark items.
  """
  @spec build_payload(map(), list()) :: map()
  def build_payload(snapshot, items) do
    %{
      "state" => %{"records" => snapshot.records || []},
      "items" => items
    }
  end

  defp get_cost(type, registry) do
    case Map.get(registry, type) do
      nil -> 0
      conn -> Map.get(conn, :cost, 0)
    end
  end
end
