defmodule AgentOS.RunWorker do
  @moduledoc """
  Implements the end-to-end enforcement-spine run pipeline:
  provision → snapshot → port → output check → act-on-behalf → run-log.

  Exposes `run_once/1` which returns `:ok | {:error, reason}` without raising,
  and a supervised `start_link/1` wrapper which raises on error to drive transient
  restart-once supervision.
  """

  alias AgentOS.Provisioner
  alias AgentOS.Manifest
  alias AgentOS.StateStore
  alias AgentOS.PortRunner
  alias AgentOS.OutputCheck
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
        _ -> %{
          agent_cmd: "python",
          agent_args: ["agents/discovery/main.py"],
          manifest_path: "manifests/discovery.md"
        }
      end

    # Retrieve overrides from opts, falling back to configuration values.
    cmd = Keyword.get(opts, :agent_cmd, cfg.agent_cmd)
    args = Keyword.get(opts, :agent_args, cfg.agent_args)
    manifest_path = Keyword.get(opts, :manifest_path, cfg.manifest_path)
    run_log_path = Keyword.get(opts, :run_log_path, Path.join(["data", "run_log.md"]))
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    # `with` is a special Elixir expression used to chain a sequence of pattern matches.
    # Each clause is evaluated in order. If all match, the `do` block is executed.
    # If any match fails, execution halts immediately and jumps to the `else` block,
    # returning the value of the failed match.
    with {:ok, manifest} <- Manifest.load(manifest_path),
         # 1. Take a snapshot of the current roster state.
         snapshot <- StateStore.snapshot("roster_trust"),
         
         # 2. Encode input into a JSON binary.
         # DATA CONTRACT: Send the list of records directly under the "roster" key.
         input_json <- Jason.encode!(%{ "roster" => snapshot.records || [] }),
         
         # 3. Run the python workload via PortRunner, capturing output or returning timeout/exits.
         {:ok, stdout} <- PortRunner.run(input_json, cmd, args, timeout_ms: timeout_ms),
         
         # 4. Decode output actions JSON.
         # Jason.decode!/1 parses the string into an Elixir map.
         %{"actions" => actions} <- Jason.decode!(stdout),
         
         # 5. Filter and validate actions against the loaded manifest rules.
         {:ok, accepted} <- OutputCheck.validate(actions, manifest) do

      # --- Happy Path: All matches succeeded ---
      # Execute all accepted actions sequentially.
      Effector.act_all(accepted)
      
      # Append a success trace to the run log.
      RunLog.append(%{status: :ok, actions: length(accepted), note: "run complete"}, path: run_log_path)
      
      # Return success atom.
      :ok
    else
      # --- Error Path: One of the matches failed ---
      # Catch standard error tuples.
      {:error, reason} ->
        # Log failure to the run log file.
        RunLog.append(%{status: :error, actions: 0, note: inspect(reason)}, path: run_log_path)
        # Return the error tuple.
        {:error, reason}

      # Catch any other unexpected values returned by the chain.
      other ->
        RunLog.append(%{status: :error, actions: 0, note: "unexpected pipeline stage result: #{inspect(other)}"}, path: run_log_path)
        {:error, other}
    end
  end
end
