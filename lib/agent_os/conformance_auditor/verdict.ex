defmodule AgentOS.ConformanceAuditor.Verdict do
  @moduledoc """
  Represents the auditor's output for one agent.
  """

  alias AgentOS.ConformanceAuditor.Flag

  @enforce_keys [:agent, :status, :flags, :computed_at]
  defstruct [:agent, :status, :flags, :computed_at]

  @type status :: :clean | :flagged | :insufficient_data

  @type t :: %__MODULE__{
          agent: String.t(),
          status: status(),
          flags: [Flag.t()],
          computed_at: DateTime.t()
        }
end
