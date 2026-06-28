defmodule AgentOS.Manifest.Grant do
  @moduledoc """
  Defines a grant within the agent manifest.
  Carries the author-controlled scope constraints for a connector.
  """

  @enforce_keys [:connector]
  defstruct [:connector, :recipients, :methods]

  @type t :: %__MODULE__{
          connector: String.t(),
          recipients: [String.t()] | nil,
          methods: [String.t()] | nil
        }
end
