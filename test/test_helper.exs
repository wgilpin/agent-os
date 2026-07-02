# Exclude container/docker tests by default to keep the local suite hermetic.
# Run them explicitly via: mix test --include docker
System.put_env("SEARCH_API_KEY", "test_search_api_key_value")
ExUnit.start(exclude: [:docker])

defmodule AgentOS.TestHelper do
  def start_mounts!(initial_spend \\ %{}, initial_approvals \\ %{approvals: %{}}) do
    uniq = System.unique_integer([:positive])
    tmp_dir = System.tmp_dir!()

    roster_path = Path.join(tmp_dir, "roster_#{uniq}.db")
    spend_path = Path.join(tmp_dir, "spend_#{uniq}.db")
    approvals_path = Path.join(tmp_dir, "approvals_#{uniq}.db")
    admitted_plugins_path = Path.join(tmp_dir, "admitted_plugins_#{uniq}.db")
    conformance_path = Path.join(tmp_dir, "conformance_#{uniq}.db")
    provenance_path = Path.join(tmp_dir, "provenance_#{uniq}.db")
    judge_path = Path.join(tmp_dir, "judge_#{uniq}.db")
    review_path = Path.join(tmp_dir, "review_#{uniq}.db")

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(roster_path)
      File.rm(spend_path)
      File.rm(approvals_path)
      File.rm(admitted_plugins_path)
      File.rm(conformance_path)
      File.rm(provenance_path)

      try do
        File.rm(judge_path)
      rescue
        _ -> :ok
      end

      try do
        File.rm(review_path)
      rescue
        _ -> :ok
      end
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
      {AgentOS.StateStore, name: "admitted_plugins", path: admitted_plugins_path, initial: %{}}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "conformance", path: conformance_path, initial: %{}}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "provenance", path: provenance_path, initial: %{}}
    )

    default_pass = %{status: :pass, code_hash: ""}

    default_review_pass = %AgentOS.Pipeline.Stage5.Verdict{
      status: :pass,
      reasoning: "ok",
      timestamp: DateTime.utc_now(),
      code_hash: ""
    }

    initial_judge = %{
      "discovery" => default_pass,
      "spend_agent" => default_pass,
      "restart_agent" => default_pass,
      "alert_agent" => default_pass,
      "roster_agent" => default_pass,
      "mixed_agent" => default_pass,
      "conformance_agent" => default_pass,
      "drift_agent" => default_pass,
      "test_agent" => default_pass
    }

    initial_review = %{
      "discovery" => default_review_pass,
      "spend_agent" => default_review_pass,
      "restart_agent" => default_review_pass,
      "alert_agent" => default_review_pass,
      "roster_agent" => default_review_pass,
      "mixed_agent" => default_review_pass,
      "conformance_agent" => default_review_pass,
      "drift_agent" => default_review_pass,
      "test_agent" => default_review_pass
    }

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "judge_results", path: judge_path, initial: initial_judge}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore,
       name: "security_review_results", path: review_path, initial: initial_review}
    )

    %{
      roster_path: roster_path,
      spend_ledger_path: spend_path,
      pending_approvals_path: approvals_path,
      conformance_path: conformance_path,
      provenance_path: provenance_path,
      judge_path: judge_path,
      review_path: review_path
    }
  end
end
