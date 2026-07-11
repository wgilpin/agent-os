defmodule AgentOS.Application do
  @moduledoc false

  use Application
  require Logger

  # `@impl true` signals to the compiler that this function implements a callback
  # from the Application module behaviour.
  @impl true
  def start(_type, _args) do
    # Boot guard (feature 045, FR-011/SC-007): the substrate runs ONLY containerized on macOS.
    # A host-run BEAM broker listens on the macOS host kernel while agent containers run in the
    # OrbStack Linux VM kernel, so agents get ECONNREFUSED on the inference socket — a half-working
    # substrate whose agents are dead. Refuse that state loudly instead of coming up broken. Test
    # runs (autostart disabled) and the in-container app (AOS_IN_CONTAINER set) are unaffected.
    boot_guard!()

    # Resolve credentials at startup
    credentials = AgentOS.CredentialSource.resolve_credentials()

    # Log a critical diagnostic if model key is missing/blank
    if is_nil(Map.get(credentials, :model_key)) do
      Logger.error("CRITICAL: Required model credential :model_key is missing or blank.")
    end

    # Store resolved credentials in the application environment
    Application.put_env(:agent_os, :credentials, credentials)

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
           path: Application.get_env(:agent_os, :roster_path, "data/roster.db"),
           initial: %{records: []}},
          {AgentOS.StateStore,
           name: "spend_ledger",
           path: Application.get_env(:agent_os, :spend_ledger_path, "data/spend_ledger.db"),
           initial: %{}},
          {AgentOS.StateStore,
           name: "pending_approvals",
           path:
             Application.get_env(
               :agent_os,
               :pending_approvals_path,
               "data/pending_approvals.db"
             ),
           initial: %{approvals: %{}}},
          {AgentOS.StateStore,
           name: "admitted_plugins",
           path:
             Application.get_env(
               :agent_os,
               :admitted_plugins_path,
               "data/admitted_plugins.db"
             ),
           initial: %{}},
          {AgentOS.StateStore,
           name: "conformance",
           path: Application.get_env(:agent_os, :conformance_path, "data/conformance.db"),
           initial: %{}},
          {AgentOS.StateStore,
           name: "provenance",
           path: Application.get_env(:agent_os, :provenance_path, "data/provenance.db"),
           initial: %{}},
          {AgentOS.StateStore,
           name: "judge_results",
           path: Application.get_env(:agent_os, :judge_results_path, "data/judge_results.db"),
           initial: %{}},
          {AgentOS.StateStore,
           name: "pipeline_runs",
           path: Application.get_env(:agent_os, :pipeline_runs_path, "data/pipeline_runs.db"),
           initial: %{}},
          # "check_reruns" records the outcome of user-triggered "Re-run checks"
          # recovery runs (spec 043), keyed by agent name. Sole writer is
          # AgentOS.Pipeline.Rerun.
          {AgentOS.StateStore,
           name: "check_reruns",
           path: Application.get_env(:agent_os, :check_reruns_path, "data/check_reruns.db"),
           initial: %{}},
          {AgentOS.StateStore,
           name: "security_review_results",
           path:
             Application.get_env(
               :agent_os,
               :security_review_results_path,
               "data/security_review_results.db"
             ),
           initial: %{}},
          {AgentOS.StateStore,
           name: "action_transcript",
           path:
             Application.get_env(:agent_os, :action_transcript_path, "data/action_transcript.db"),
           initial: %{}},
          # "deployments" is the durable deployment registry: which agents are
          # deployed and active. Sole writer is AgentOS.DeploymentRegistry.
          {AgentOS.StateStore,
           name: "deployments",
           path: Application.get_env(:agent_os, :deployments_path, "data/deployments.db"),
           initial: %{}},
          AgentOS.CredentialProxy,
          AgentOS.InferenceBroker,
          {AgentOS.InferencePriceSync, []},
          {Phoenix.PubSub, name: AgentOS.PubSub},
          AgentOSWeb.Endpoint,

          # ConnectorSupervisor isolates dynamic connector executions
          {Task.Supervisor, name: AgentOS.ConnectorSupervisor},

          # PipelineTaskSupervisor runs UI-started generation pipelines detached
          # from the LiveView process, so a run survives the browser session.
          {Task.Supervisor, name: AgentOS.PipelineTaskSupervisor},

          # RunLock enforces one re-run/pipeline run per agent at a time (spec 043,
          # FR-009): the "Re-run checks" action claims it before spawning its task.
          AgentOS.Pipeline.RunLock,

          # RunSupervisor handles starting and retrying worker execution tasks.
          AgentOS.RunSupervisor,

          # TriggerGateway handles incoming trigger signals (event, message, approval-resume).
          AgentOS.TriggerGateway,

          # TriggerArming re-arms deployed agents' manifest time triggers from the
          # durable deployment registry at boot (no catch-up of missed windows).
          {AgentOS.TriggerArming, []},

          # Scheduler is the GenServer running the daily 07:00 self-rescheduling timer loop.
          {AgentOS.Scheduler, []},

          # DiscordGateway maintains the websocket connection to Discord.
          AgentOS.DiscordGateway,

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

  # Raises (aborting application start) when a real substrate boot is attempted on the macOS host
  # outside the container. Reads the three signals from the environment and delegates the decision
  # to the pure `boot_permitted?/3` (unit-tested directly, without killing a running VM).
  defp boot_guard! do
    autostart? = Application.get_env(:agent_os, :autostart, true)
    in_container? = System.get_env("AOS_IN_CONTAINER") not in [nil, ""]

    case boot_permitted?(autostart?, in_container?, :os.type()) do
      :ok ->
        :ok

      {:refused, message} ->
        Logger.error(message)
        raise message
    end
  end

  @typedoc "The outcome of the host/container boot guard."
  @type boot_decision() :: :ok | {:refused, String.t()}

  @doc """
  Pure boot-guard decision (feature 045, FR-011). Refuses ONLY the one broken topology — a real
  app start (autostart enabled) on the macOS host outside the container — and permits everything
  else:

    * `autostart?` false        -> `:ok` (the hermetic test suite; no supervision tree comes up).
    * `in_container?` true       -> `:ok` (the containerized substrate — the sole real run mode).
    * OS is not `{:unix, :darwin}` -> `:ok` (Linux host / CI; the UDS is kernel-local either way).
    * else (autostart + host + macOS) -> `{:refused, message}` naming the container entry point.
  """
  @spec boot_permitted?(boolean(), boolean(), {atom(), atom()}) :: boot_decision()
  def boot_permitted?(autostart?, in_container?, os_type)
  def boot_permitted?(false, _in_container?, _os_type), do: :ok
  def boot_permitted?(_autostart?, true, _os_type), do: :ok

  def boot_permitted?(true, false, {:unix, :darwin}) do
    {:refused,
     "AgentOS refuses to start: the substrate runs only containerized on macOS. A host-run BEAM " <>
       "broker cannot be reached by sandboxed agents (the inference Unix socket is kernel-local, " <>
       "so agents in the OrbStack VM get ECONNREFUSED against a broker on the host kernel). " <>
       "Start the substrate with `docker compose up substrate` instead. " <>
       "(Set AOS_IN_CONTAINER=1 only when actually running inside the container.)"}
  end

  def boot_permitted?(_autostart?, _in_container?, _os_type), do: :ok
end
