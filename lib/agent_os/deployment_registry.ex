defmodule AgentOS.DeploymentRegistry do
  @moduledoc """
  The sole writer to the durable `"deployments"` StateStore (Constitution IX).

  Records which agents are deployed, making "deployed" a first-class,
  restart-surviving runtime state. Trigger dispatch consults this registry via
  `deployed_and_active?/1`; boot re-arming reads `list_active/0`. Registry
  membership gates dispatch only — it grants no capability (Constitution X/XI).

  Production write sites (the ONLY two):
    1. `AgentOS.Provisioner.deploy/3` — direct, non-blocking deploy success.
    2. `AgentOS.TriggerGateway` — approval-resume completing a deploy-shaped action.
  """

  require Logger

  alias AgentOS.DeploymentRecord
  alias AgentOS.StateStore

  @store "deployments"

  @doc """
  Upserts the deployment record for `agent_name`: sets `active: true` and a fresh
  `deployed_at`. Redeployment replaces the record — never duplicates it; prior
  deploy history remains in the "provenance" store.
  """
  @spec record_deployment(String.t(), String.t(), DeploymentRecord.provenance()) :: :ok
  def record_deployment(agent_name, manifest_path, provenance)
      when is_binary(agent_name) and is_binary(manifest_path) and is_atom(provenance) do
    record = %DeploymentRecord{
      agent_name: agent_name,
      manifest_path: manifest_path,
      deployed_at: DateTime.utc_now(),
      provenance: provenance,
      active: true
    }

    StateStore.apply_action(@store, {:put, agent_name, record})
  end

  @doc """
  Returns the deployment record for `agent_name`, or nil if never deployed.
  """
  @spec get(String.t()) :: DeploymentRecord.t() | nil
  def get(agent_name) when is_binary(agent_name) do
    Map.get(StateStore.snapshot(@store), agent_name)
  end

  @doc """
  Returns all records with `active: true` — the set of agents whose triggers
  may dispatch and get re-armed at boot.
  """
  @spec list_active() :: [DeploymentRecord.t()]
  def list_active do
    @store
    |> StateStore.snapshot()
    |> Map.values()
    |> Enum.filter(& &1.active)
  end

  @doc """
  Dispatch-gate predicate: true only for a registered record with `active: true`.
  """
  @spec deployed_and_active?(String.t()) :: boolean()
  def deployed_and_active?(agent_name) when is_binary(agent_name) do
    case get(agent_name) do
      %DeploymentRecord{active: active} -> active
      nil -> false
    end
  end

  @doc """
  Flips `active` to false, preserving the rest of the record (e.g. when the
  manifest file backing an active record is missing at boot). Warns and no-ops
  if the agent was never deployed.
  """
  @spec mark_inactive(String.t()) :: :ok
  def mark_inactive(agent_name) when is_binary(agent_name) do
    case get(agent_name) do
      %DeploymentRecord{} = record ->
        StateStore.apply_action(@store, {:put, agent_name, %{record | active: false}})

      nil ->
        Logger.warning(
          "DeploymentRegistry: mark_inactive for unknown agent #{inspect(agent_name)} — no-op"
        )

        :ok
    end
  end
end
