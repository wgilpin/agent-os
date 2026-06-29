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

  Returns `:ok` or `{:error, reason}`.
  """
  @spec act(%{action: ProposedAction.t(), grant: AgentOS.Manifest.Grant.t()}) ::
          :ok | {:error, any()}
  def act(%{action: %ProposedAction{type: "kv_append", method: "append", payload: payload}}) do
    AgentOS.StateStore.apply_action("roster_trust", {:append, :records, payload})
  end

  def act(%{action: %ProposedAction{type: "external_send"} = action}) do
    registry = AgentOS.Connector.registry()

    case Map.fetch(registry, "external_send") do
      {:ok, %{credential: nil}} ->
        AgentOS.Connector.external_send_sink(action, "")

      {:ok, %{credential: credential_id}} ->
        case AgentOS.CredentialProxy.with_credential(credential_id, fn secret ->
               AgentOS.Connector.external_send_sink(action, secret)
             end) do
          :ok ->
            :ok

          {:error, {:unknown_credential, id}} ->
            Logger.error(
              "Failed to execute external_send: unknown credential :#{id}. Failing closed."
            )

            {:error, {:unknown_credential, id}}
        end

      _ ->
        {:error, {:unknown_action, "external_send"}}
    end
  end

  def act(%{action: %ProposedAction{type: other_type}}) do
    {:error, {:unknown_action, other_type}}
  end

  @doc """
  Maps the execution of multiple approved actions in order.
  Returns `:ok`.

  ### Known Limitation:
  Currently discards per-action return values/errors (swallowing errors like `{:error, {:unknown_credential, id}}`).
  Batch error aggregation is out of scope for spec 004 and is deferred.
  """
  @spec act_all([%{action: ProposedAction.t(), grant: AgentOS.Manifest.Grant.t()}]) :: :ok
  def act_all(approved_actions) when is_list(approved_actions) do
    Enum.each(approved_actions, &act/1)
    :ok
  end
end
