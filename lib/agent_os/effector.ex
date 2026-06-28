defmodule AgentOS.Effector do
  @moduledoc """
  The effector is the SOLE privileged action execution path in the substrate.
  The agent only proposes actions; it never holds credentials and never mutates
  state directly.
  """

  alias AgentOS.ProposedAction

  @doc """
  Executes a single gate-approved action on the agent's behalf.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec act(%{action: ProposedAction.t(), grant: AgentOS.Manifest.Grant.t()}) :: :ok | {:error, any()}
  def act(%{action: %ProposedAction{type: "kv_append", method: "append", payload: payload}}) do
    AgentOS.StateStore.apply_action("roster_trust", {:append, :records, payload})
  end

  def act(%{action: %ProposedAction{type: "external_send"} = _action}) do
    # external_send mock sink. Credential proxy injection is wired in US3 (Phase 5).
    :ok
  end

  def act(%{action: %ProposedAction{type: other_type}}) do
    {:error, {:unknown_action, other_type}}
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
end
