defmodule AgentOS.ConformanceAuditor.Flag do
  @moduledoc """
  Represents a single raised conformance signal.
  """

  @enforce_keys [:type, :severity, :description]
  defstruct [:type, :severity, :description]

  @type type :: :quiet | :sick | :denied_approval | :gate_breach
  @type severity :: :health | :count | :tripwire

  @type t :: %__MODULE__{
          type: type(),
          severity: severity(),
          description: String.t()
        }

  @doc """
  Returns true if severity1 is less than severity2 based on the order:
  :health < :count < :tripwire.
  """
  @spec less_than?(severity(), severity()) :: boolean()
  def less_than?(:health, :count), do: true
  def less_than?(:health, :tripwire), do: true
  def less_than?(:count, :tripwire), do: true
  def less_than?(_, _), do: false
end
