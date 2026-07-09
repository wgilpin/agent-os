defmodule AgentOS.DeploymentRecord do
  @moduledoc """
  The typed registry entry that makes "deployed" a durable, restart-surviving state.

  One record per agent, keyed by `agent_name` in the `"deployments"` StateStore.
  Written exclusively by `AgentOS.DeploymentRegistry` (single-writer, Constitution IX).
  Registry membership gates trigger dispatch only — it confers no capability; the
  manifest grants remain the agent's entire power (Constitution X/XI).
  """

  @type provenance :: :reviewed_human | :skipped_in_envelope | :dangerously_skipped

  @type t :: %__MODULE__{
          agent_name: String.t(),
          manifest_path: String.t(),
          deployed_at: DateTime.t(),
          provenance: provenance(),
          active: boolean()
        }

  @enforce_keys [:agent_name, :manifest_path, :deployed_at, :provenance, :active]
  defstruct [:agent_name, :manifest_path, :deployed_at, :provenance, :active]
end
