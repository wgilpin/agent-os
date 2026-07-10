defmodule AgentOS.Pipeline.RunLock do
  @moduledoc """
  In-flight lock enforcing at most one re-run (or pipeline run) per agent at a time
  (spec 043, FR-009).

  A tiny GenServer holding a `MapSet` of agent names currently running. The
  "Re-run checks" entry point (`AgentOS.Pipeline.Rerun.start/2`) claims the lock
  synchronously — so a concurrent request is refused immediately with `{:error, :busy}`
  — and the detached run task releases it when it finishes.

  All three public calls are tolerant of the process being absent (e.g. a minimal test
  tree that does not start the lock): absence means "not busy" / a no-op, logged at debug.
  The set is intentionally not persisted — no run survives a node restart, so a stale
  lock can never outlive the run it guarded.
  """

  use GenServer
  require Logger

  @name __MODULE__

  @doc """
  Starts the lock. `:name` defaults to the module name (the singleton used in production).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, %{in_flight: MapSet.new()}, name: name)
  end

  @doc """
  Claims the lock for `agent_name`. Returns `:ok` if it was free, `{:error, :busy}` if a
  run is already in flight for that agent. If the lock process is not running, claiming
  succeeds (no enforcement in a minimal tree).
  """
  @spec claim(String.t(), GenServer.server()) :: :ok | {:error, :busy}
  def claim(agent_name, server \\ @name) when is_binary(agent_name) do
    safe_call(server, {:claim, agent_name}, :ok)
  end

  @doc """
  Releases the lock for `agent_name` (idempotent). No-op if the process is absent.
  """
  @spec release(String.t(), GenServer.server()) :: :ok
  def release(agent_name, server \\ @name) when is_binary(agent_name) do
    safe_call(server, {:release, agent_name}, :ok)
  end

  @doc """
  Returns whether a run is currently in flight for `agent_name`. `false` if the process
  is absent.
  """
  @spec busy?(String.t(), GenServer.server()) :: boolean()
  def busy?(agent_name, server \\ @name) when is_binary(agent_name) do
    safe_call(server, {:busy?, agent_name}, false)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:claim, agent_name}, _from, %{in_flight: set} = state) do
    if MapSet.member?(set, agent_name) do
      {:reply, {:error, :busy}, state}
    else
      {:reply, :ok, %{state | in_flight: MapSet.put(set, agent_name)}}
    end
  end

  @impl true
  def handle_call({:release, agent_name}, _from, %{in_flight: set} = state) do
    {:reply, :ok, %{state | in_flight: MapSet.delete(set, agent_name)}}
  end

  @impl true
  def handle_call({:busy?, agent_name}, _from, %{in_flight: set} = state) do
    {:reply, MapSet.member?(set, agent_name), state}
  end

  # Calls the lock tolerantly: if it is not running (minimal test tree), fall back to
  # `default` rather than crashing the caller — the lock is a guard, not a hard dependency.
  defp safe_call(server, message, default) do
    GenServer.call(server, message)
  catch
    :exit, reason ->
      Logger.debug("RunLock: #{inspect(message)} unavailable: #{inspect(reason)} — continuing")
      default
  end
end
