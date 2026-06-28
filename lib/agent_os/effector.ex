defmodule AgentOS.Effector do
  @moduledoc """
  The effector is the SOLE privileged action execution path in the substrate.
  The agent only proposes actions; it never holds credentials and never mutates
  state directly (DEC-remove-llm-from-credential-boundary).
  """

  @doc """
  Executes a single validated action on the agent's behalf.

  Actions:
    - `"record_signal"`: Records a payload map into the StateStore.
    - `"append_digest"`: Records a digest `%{"digest" => text}` into the StateStore at v0.
      (In Plan 05 this will be extended to append to the run-log file).

  Returns `:ok` or `{:error, reason}`.
  """
  @spec act(map()) :: :ok | {:error, any()}
  def act(%{"type" => "record_signal", "payload" => payload}) when is_map(payload) do
    AgentOS.StateStore.apply_action("roster_trust", {:append, :records, payload})
  end

  def act(%{"type" => "append_digest", "payload" => %{"text" => text}}) when is_binary(text) do
    # At v0, record via StateStore to avoid file-ownership conflicts with Plan 05's RunLog
    AgentOS.StateStore.apply_action("roster_trust", {:append, :records, %{"digest" => text}})
  end

  def act(%{"type" => other_type}) do
    {:error, {:unknown_action, other_type}}
  end

  @doc """
  Maps the execution of multiple actions in order.
  Returns `:ok`.
  """
  @spec act_all([map()]) :: :ok
  def act_all(actions) when is_list(actions) do
    Enum.each(actions, &act/1)
    :ok
  end
end
