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
          {AgentOS.StateStore,
           name: "spend_ledger",
           path: Application.get_env(:agent_os, :spend_ledger_path, "data/spend_ledger.term"),
           initial: %{}},
          {AgentOS.StateStore,
           name: "pending_approvals",
           path:
             Application.get_env(
               :agent_os,
               :pending_approvals_path,
               "data/pending_approvals.term"
             ),
           initial: %{approvals: %{}}},
          {AgentOS.StateStore,
           name: "conformance",
           path: Application.get_env(:agent_os, :conformance_path, "data/conformance.term"),
           initial: %{}},
          {AgentOS.StateStore,
           name: "provenance",
           path: Application.get_env(:agent_os, :provenance_path, "data/provenance.term"),
           initial: %{}},
          {AgentOS.StateStore,
           name: "judge_results",
           path:
             Application.get_env(:agent_os, :judge_results_path, "data/judge_results.term"),
           initial: %{}},
          AgentOS.CredentialProxy,
          AgentOS.InferenceBroker,

          # RunSupervisor handles starting and retrying worker execution tasks.
          AgentOS.RunSupervisor,

          # TriggerGateway handles incoming trigger signals (event, message, approval-resume).
          AgentOS.TriggerGateway,

          # Scheduler is the GenServer running the daily 07:00 self-rescheduling timer loop.
          {AgentOS.Scheduler, []},

          # ConformanceAuditor.Scheduler reschedules itself daily to run the conformance audit.
          {AgentOS.ConformanceAuditor.Scheduler, []}
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
