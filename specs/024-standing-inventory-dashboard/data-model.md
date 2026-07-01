# Data Model: Standing Inventory Dashboard

## Structured Accessor Map

The accessor `AgentOS.Inventory.data/1` returns `{:ok, data}` where `data` is a map with the following structure:

```elixir
%{
  agent_name: String.t(),
  purpose: String.t(),
  triggers: [any()],
  mounts: [any()],
  owner: String.t(),
  supervision: String.t(),
  spend: %{
    cap: non_neg_integer(),
    window: String.t() | atom(),
    spent: non_neg_integer()
  },
  records_count: non_neg_integer(),
  last_digest: String.t(),
  last_run: %{
    status: String.t(),
    trigger: String.t(),
    actions: String.t() | non_neg_integer(),
    exit_code: String.t() | nil,
    failure_cause: String.t() | nil,
    items_in: String.t() | non_neg_integer(),
    items_dropped: String.t() | non_neg_integer()
  },
  provenance: %{status: atom(), hash: String.t(), failure_reason: atom() | nil} | nil,
  conformance: AgentOS.ConformanceAuditor.Verdict.t() | nil,
  judge: %{status: atom(), last_run: DateTime.t() | nil, reasoning: String.t() | nil} | nil,
  security_review: %{status: atom(), timestamp: DateTime.t() | nil, reasoning: String.t() | nil} | nil,
  pending_approvals: [%{ref: String.t(), action: AgentOS.ProposedAction.t(), grant: AgentOS.Manifest.Grant.t()}],
  capabilities: [AgentOS.CapabilityRender.Entry.t()]
}
```

---

## LiveView Socket Assigns

`AgentOSWeb.InventoryLive` keeps the following assigns:

* `agents_data`: A list of maps, where each map is the output of `AgentOS.Inventory.data/1` for one of the detected manifests.
* `last_updated`: A `DateTime` indicating when the data was last polled.

---

## State Transitions & Polling

1. **Mount**:
   * Scans `manifests/*.md` for manifests.
   * Loads inventory data for each manifest.
   * Schedules next tick with `Process.send_after(self(), :tick, 5000)`.
2. **Tick Handler (`handle_info/2` on `:tick`)**:
   * Re-loads inventory data for each manifest.
   * Re-assigns `agents_data` and `last_updated`.
   * Schedules next tick with `Process.send_after(self(), :tick, 5000)`.
