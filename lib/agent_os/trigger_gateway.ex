defmodule AgentOS.TriggerGateway do
  @moduledoc """
  The only substrate-side intake for event, message, and approval-resume triggers.
  """

  use GenServer
  require Logger

  @type signal ::
          {:event, name :: String.t(), payload :: term()}
          | {:message, agent :: String.t(), content :: term()}
          | {:approval, decision :: :approve | :deny, ref :: String.t()}

  @doc """
  Starts the TriggerGateway GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts_without_name} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts_without_name, name: name)
  end

  @doc """
  Submits an admitted signal asynchronously.
  """
  @spec submit(signal()) :: :ok
  def submit(signal) do
    GenServer.cast(__MODULE__, {:submit, signal})
  end

  @doc """
  Synchronous dispatch of a signal.
  """
  @spec submit_sync(signal(), keyword()) ::
          {:fired, [String.t()]}
          | {:resolved, :approved | :denied | :unknown_ref}
          | {:rejected, atom()}
  def submit_sync(signal, opts \\ []) do
    do_dispatch(signal, opts)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def handle_cast({:submit, signal}, state) do
    do_dispatch(signal, state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:submit_sync, signal, opts}, _from, state) do
    merged_opts = Keyword.merge(state, opts)
    res = do_dispatch(signal, merged_opts)
    {:reply, res, state}
  end

  # --- Private Dispatch Logic ---

  defp do_dispatch(signal, opts) do
    case signal do
      {:event, name, payload} ->
        dispatch_event(name, payload, opts)

      {:message, agent, content} ->
        dispatch_message(agent, content, opts)

      {:approval, decision, ref} ->
        dispatch_approval(decision, ref, opts)
    end
  end

  defp dispatch_event(name, payload, opts) do
    if name == "" or String.contains?(name, " ") or String.contains?(name, "\t") or
         String.contains?(name, "\n") do
      Logger.warning("TriggerGateway: invalid event name: #{inspect(name)}")
      {:rejected, :invalid_event_name}
    else
      manifests_fn = Keyword.get(opts, :manifests_fn, &default_manifests/0)
      start_run_fn = Keyword.get(opts, :start_run_fn, &AgentOS.RunSupervisor.start_run/1)

      manifests = manifests_fn.()

      matching_agents =
        Enum.filter(manifests, fn {_agent, manifest} ->
          Enum.any?(manifest.triggers, fn
            %{type: :event, name: ^name} -> true
            _ -> false
          end)
        end)

      case matching_agents do
        [] ->
          Logger.info("TriggerGateway: no agent declares event #{inspect(name)}")
          {:fired, []}

        agents ->
          fired_agents =
            Enum.map(agents, fn {agent_name, _manifest} ->
              start_run_fn.(trigger: "event:" <> name, trigger_input: payload, agent: agent_name)
              agent_name
            end)

          {:fired, fired_agents}
      end
    end
  end

  defp dispatch_message(agent_name, content, opts) do
    manifests_fn = Keyword.get(opts, :manifests_fn, &default_manifests/0)
    start_run_fn = Keyword.get(opts, :start_run_fn, &AgentOS.RunSupervisor.start_run/1)

    manifests = manifests_fn.()

    case Map.fetch(manifests, agent_name) do
      :error ->
        Logger.warning("TriggerGateway: message sent to unknown agent: #{inspect(agent_name)}")
        {:rejected, :unknown_agent}

      {:ok, manifest} ->
        has_message_trigger =
          Enum.any?(manifest.triggers, fn
            %{type: :message} -> true
            _ -> false
          end)

        if has_message_trigger do
          start_run_fn.(trigger: "message", trigger_input: content, agent: agent_name)
          {:fired, [agent_name]}
        else
          Logger.warning(
            "TriggerGateway: agent #{inspect(agent_name)} does not declare message trigger"
          )

          {:rejected, :no_message_trigger}
        end
    end
  end

  defp dispatch_approval(decision, ref, opts) do
    effector_fn = Keyword.get(opts, :effector_fn, &AgentOS.Effector.act/1)

    run_log_opts =
      if path = Keyword.get(opts, :run_log_path) do
        [path: path]
      else
        []
      end

    pending_store = AgentOS.StateStore.snapshot("pending_approvals")
    approvals = Map.get(pending_store, :approvals, %{})

    case Map.get(approvals, ref) do
      nil ->
        Logger.warning("TriggerGateway: approval for unknown ref #{inspect(ref)} - no-op")
        {:resolved, :unknown_ref}

      %{action: action, grant: grant} ->
        # 1. REMOVE FIRST (single-writer StateStore) — makes execution at-most-once.
        :ok =
          AgentOS.StateStore.apply_action("pending_approvals", {:delete_in, [:approvals, ref]})

        case decision do
          :approve ->
            effector_fn.(%{action: action, grant: grant})

            AgentOS.RunLog.append(
              %{
                status: :ok,
                actions: 1,
                trigger: "approval-resume",
                note: "approved ref=#{ref}"
              },
              run_log_opts
            )

            {:resolved, :approved}

          :deny ->
            Logger.info("TriggerGateway: denied ref #{inspect(ref)}")

            AgentOS.RunLog.append(
              %{
                status: :ok,
                actions: 0,
                trigger: "approval-resume",
                note: "denied ref=#{ref}"
              },
              run_log_opts
            )

            {:resolved, :denied}
        end
    end
  end

  @doc """
  Default helper to load all agent manifests from the manifests/ directory.
  """
  @spec default_manifests() :: %{String.t() => AgentOS.Manifest.t()}
  def default_manifests do
    manifests_dir = "manifests"

    case File.ls(manifests_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reduce(%{}, fn file, acc ->
          path = Path.join(manifests_dir, file)
          agent_name = Path.basename(file, ".md")

          case AgentOS.Manifest.load(path) do
            {:ok, manifest} -> Map.put(acc, agent_name, manifest)
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end
end
