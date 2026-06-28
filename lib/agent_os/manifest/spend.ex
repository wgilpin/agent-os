defmodule AgentOS.Manifest.Spend do
  @moduledoc """
  Defines the spend constraints within the agent manifest.
  Carries the cap, window, and breach action.
  """

  @enforce_keys [:cap, :window, :on_breach]
  defstruct [:cap, :window, :on_breach]

  @type window :: :daily
  @type on_breach :: :kill

  @type t :: %__MODULE__{
          cap: non_neg_integer() | float(),
          window: window(),
          on_breach: on_breach()
        }
end
