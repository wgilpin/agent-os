defmodule AgentOS.Effector do
  @moduledoc """
  The effector is the SOLE privileged action execution path in the substrate.
  The agent only proposes actions; it never holds credentials and never mutates
  state directly.

  Principle XI Invariant:
  No LLM-running component (the agent workload) holds mutating credentials. Injection
  occurs only post-approval at the chokepoint (the effector) immediately prior to execution.
  """

  alias AgentOS.ProposedAction
  require Logger

  @doc """
  Executes a single gate-approved action on the agent's behalf.

  Returns `:ok` or `{:error, any()}`.
  """
  @spec act(%{action: ProposedAction.t(), grant: AgentOS.Manifest.Grant.t()}) ::
          :ok | {:error, any()}
  def act(%{
        action: %ProposedAction{
          type: "deploy",
          recipient: agent_name,
          method: manifest_path,
          payload: %{"hash" => hash}
        }
      }) do
    :ok = AgentOS.Provisioner.record_provenance(agent_name, :reviewed_human, hash)
    AgentOS.RunSupervisor.start_run(manifest_path: manifest_path)
    :ok
  end

  def act(%{action: %ProposedAction{type: type} = action}) do
    case AgentOS.Connector.get_module(type) do
      {:ok, mod} ->
        meta = mod.metadata()

        case meta.credential do
          nil ->
            execute_isolated(mod, action, nil)

          credential_id ->
            case AgentOS.CredentialProxy.with_credential(credential_id, fn secret ->
                   execute_isolated(mod, action, secret)
                 end) do
              {:error, {:unknown_credential, id}} ->
                Logger.error(
                  "Failed to execute #{type}: unknown credential :#{id}. Failing closed."
                )

                {:error, {:unknown_credential, id}}

              result ->
                result
            end
        end

      {:error, :unknown_connector} ->
        {:error, {:unknown_action, type}}
    end
  end

  @doc """
  Maps the execution of multiple approved actions in order.
  Returns `:ok`.
  """
  @spec act_all([%{action: ProposedAction.t(), grant: AgentOS.Manifest.Grant.t()}]) :: :ok
  def act_all(approved_actions) when is_list(approved_actions) do
    Enum.each(approved_actions, &act/1)
    :ok
  end

  # Helpers

  defp execute_isolated(mod, action, secret) do
    # Resolve supervisor name or pid
    {sup, should_stop?} =
      case Process.whereis(AgentOS.ConnectorSupervisor) do
        nil ->
          {:ok, pid} = Task.Supervisor.start_link()
          {pid, true}

        pid ->
          {pid, false}
      end

    # Spawn task under Supervisor without linking
    task =
      Task.Supervisor.async_nolink(sup, fn ->
        try do
          mod.execute(action, secret)
        rescue
          e ->
            Logger.error("Connector #{mod.metadata().name} raised exception: #{inspect(e)}")
            {:error, {:raised, e}}
        catch
          kind, reason ->
            Logger.error("Connector #{mod.metadata().name} caught: #{inspect({kind, reason})}")

            {:error, {:caught, kind, reason}}
        end
      end)

    # Yield to task with a 5000 ms timeout
    result =
      case Task.yield(task, 5000) || Task.shutdown(task) do
        {:ok, val} ->
          val

        nil ->
          Logger.error("Connector #{mod.metadata().name} execution timed out. Failing closed.")
          {:error, :timeout}

        {:exit, reason} ->
          Logger.error(
            "Connector #{mod.metadata().name} exited: #{inspect(reason)}. Failing closed."
          )

          {:error, {:exit, reason}}
      end

    # Clean up the dynamic supervisor if we started it
    if should_stop? do
      GenServer.stop(sup)
    end

    result
  end
end
