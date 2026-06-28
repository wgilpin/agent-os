defmodule AgentOS.RunSupervisor do
  @moduledoc """
  Implements the restart-once-and-alert supervisor policy (REQ-restart-policy).
  At v0, it manages the execution attempts of the run pipeline. It runs the pipeline
  once; on abnormal exit it retries exactly once; on the second consecutive failure,
  it halts and triggers the Alerter.
  """

  use GenServer

  require Logger

  @doc """
  Starts the RunSupervisor process and registers its name globally.
  """
  def start_link(opts \\ []) do
    # GenServer.start_link/3 starts the GenServer. __MODULE__ resolves to the current
    # module name (AgentOS.RunSupervisor). The third argument registers the name
    # under this module name so we can call it directly without pid reference.
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers a run execution under the supervisor tree.
  It executes asynchronously via a GenServer cast message.

  ## Parameters
    - `opts`: Keyword list allowing dependency injection for tests (e.g. `:worker_fn`).
  """
  @spec start_run(keyword()) :: :ok
  def start_run(opts \\ []) do
    # GenServer.cast/2 sends an asynchronous message to the GenServer. It returns :ok
    # immediately without waiting for a response (unlike GenServer.call).
    GenServer.cast(__MODULE__, {:start_run, opts})
  end

  # --- GenServer Callbacks ---

  # `@impl true` explicitly marks the following function as implementing a behaviour callback.
  @impl true
  def init(opts) do
    # init/1 initializes the GenServer state. We store the default options
    # passed to start_link in state.
    {:ok, %{default_opts: opts}}
  end

  @impl true
  def handle_cast({:start_run, opts}, state) do
    # Merge options passed in start_run/1 with default options from server startup state.
    merged_opts = Keyword.merge(state.default_opts, opts)

    # Executing the run pipeline can be slow. To avoid blocking the GenServer loop
    # (which would prevent it from processing other casts), we spawn a separate,
    # concurrent process using spawn/1 to handle the retry loop.
    spawn(fn -> run_loop(merged_opts, 0) end)

    # Return {:noreply, state} signifying that we don't return a value to the caller.
    {:noreply, state}
  end

  # --- Private Try/Retry Loop ---

  # Private helper function to handle the try-once-retry-once-alert loop.
  defp run_loop(opts, attempts) do
    # Resolve the worker function. Keyword.get/3 extracts the function, defaulting to
    # the real RunWorker.run_once/1 function if no test mock/override is present.
    worker_fn = Keyword.get(opts, :worker_fn, &AgentOS.RunWorker.run_once/1)

    # Execute the worker function.
    case worker_fn.(opts) do
      # If successful, exit recursion with success.
      :ok ->
        :ok

      # If an error tuple is returned:
      {:error, reason} ->
        # If we have attempted less than twice (attempts start at 0, retry runs at attempts = 1):
        if attempts < 1 do
          Logger.warning(
            "RunWorker failed (attempt #{attempts + 1}/2), retrying once... Reason: #{inspect(reason)}"
          )

          # Recursively call run_loop with attempts incremented.
          run_loop(opts, attempts + 1)
        else
          # Retries are exhausted (first attempt failed, second retry failed).
          # Trigger the Alerter to log the error and record the alert.
          AgentOS.Alerter.alert(reason, opts)
        end
    end
  end
end
