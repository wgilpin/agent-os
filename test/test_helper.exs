# Exclude container/docker tests by default to keep the local suite hermetic.
# Run them explicitly via: mix test --include docker
ExUnit.start(exclude: [:docker])

defmodule AgentOS.TestHelper do
  def start_mounts!(initial_spend \\ %{}, initial_approvals \\ %{approvals: %{}}) do
    uniq = System.unique_integer([:positive])
    tmp_dir = System.tmp_dir!()

    roster_path = Path.join(tmp_dir, "roster_#{uniq}.term")
    spend_path = Path.join(tmp_dir, "spend_#{uniq}.term")
    approvals_path = Path.join(tmp_dir, "approvals_#{uniq}.term")
    conformance_path = Path.join(tmp_dir, "conformance_#{uniq}.term")
    provenance_path = Path.join(tmp_dir, "provenance_#{uniq}.term")

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(roster_path)
      File.rm(spend_path)
      File.rm(approvals_path)
      File.rm(conformance_path)
      File.rm(provenance_path)
    end)

    if Process.whereis(AgentOS.StateStoreRegistry) == nil do
      ExUnit.Callbacks.start_supervised!(
        {Registry, keys: :unique, name: AgentOS.StateStoreRegistry}
      )
    end

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "roster_trust", path: roster_path, initial: %{records: []}}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "spend_ledger", path: spend_path, initial: initial_spend}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore,
       name: "pending_approvals", path: approvals_path, initial: initial_approvals}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "conformance", path: conformance_path, initial: %{}}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "provenance", path: provenance_path, initial: %{}}
    )

    %{
      roster_path: roster_path,
      spend_ledger_path: spend_path,
      pending_approvals_path: approvals_path,
      conformance_path: conformance_path,
      provenance_path: provenance_path
    }
  end
end
