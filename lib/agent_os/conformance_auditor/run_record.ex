defmodule AgentOS.ConformanceAuditor.RunRecord do
  @moduledoc """
  Represents a single parsed run-log record.
  """

  @type t :: %__MODULE__{
          status: String.t(),
          actions: non_neg_integer(),
          trigger: String.t() | nil,
          items_in: non_neg_integer(),
          items_dropped: non_neg_integer(),
          rejected_count: non_neg_integer(),
          parked_count: non_neg_integer(),
          breached_count: non_neg_integer(),
          gate_reasons: [String.t()],
          note: String.t()
        }

  defstruct [
    :status,
    actions: 0,
    trigger: nil,
    items_in: 0,
    items_dropped: 0,
    rejected_count: 0,
    parked_count: 0,
    breached_count: 0,
    gate_reasons: [],
    note: ""
  ]
end
