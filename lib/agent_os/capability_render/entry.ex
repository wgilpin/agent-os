defmodule AgentOS.CapabilityRender.Entry do
  @moduledoc """
  Represents a single, typed capability entry derived from a manifest grant.
  """

  @enforce_keys [:connector, :phrase, :danger, :phrase_source]
  defstruct [
    :connector,
    :phrase,
    :danger,
    :recipients,
    :methods,
    :phrase_source
  ]

  @type danger_tier :: :read_only | :local | :external

  @type t :: %__MODULE__{
          connector: String.t(),
          phrase: String.t(),
          danger: danger_tier(),
          recipients: [String.t()] | nil,
          methods: [String.t()] | nil,
          phrase_source: :mapped | :fallback
        }
end
