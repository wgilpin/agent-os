defmodule AgentOS.Application do
  @moduledoc false

  use Application

  # `@impl true` signals to the compiler that this function implements a callback
  # from the Application module behaviour.
  @impl true
  def start(_type, _args) do
    # Perform a startup drift check between config and manifest.
    # We retrieve the :autostart config flag, defaulting to true if not set.
    if Application.get_env(:agent_os, :autostart, true) do
      # Run startup consistency check to catch any manifest vs config drift early
      AgentOS.Provisioner.check_drift()
    end

    # Define child processes to start under the supervision tree.
    # In tests, :autostart is set to false, so tests manually start isolated processes.
    children =
      if Application.get_env(:agent_os, :autostart, true) do
        [
          {Registry, keys: :unique, name: AgentOS.StateStoreRegistry},
          {AgentOS.StateStore,
           name: "roster_trust",
           path: Application.get_env(:agent_os, :roster_path, "data/roster.term"),
           initial: %{records: []}},

          # RunSupervisor handles starting and retrying worker execution tasks.
          AgentOS.RunSupervisor,

          # Scheduler is the GenServer running the daily 07:00 self-rescheduling timer loop.
          {AgentOS.Scheduler, []}
        ]
      else
        # Empty tree for testing context.
        []
      end

    # Configure the supervisor strategy.
    # :one_for_one means if a child process terminates/crashes, only that child is restarted.
    opts = [strategy: :one_for_one, name: AgentOS.Supervisor]

    # Start the supervisor with the child specifications.
    Supervisor.start_link(children, opts)
  end
end
