defmodule AgentOS.InventoryTest do
  use ExUnit.Case, async: false

  alias AgentOS.Inventory
  alias AgentOS.StateStore

  setup do
    tmp_roster =
      Path.join(
        System.tmp_dir!(),
        "roster_inventory_#{System.unique_integer([:positive])}.term"
      )

    tmp_spend =
      Path.join(
        System.tmp_dir!(),
        "spend_ledger_inventory_#{System.unique_integer([:positive])}.term"
      )

    tmp_approvals =
      Path.join(
        System.tmp_dir!(),
        "pending_approvals_inventory_#{System.unique_integer([:positive])}.term"
      )

    tmp_conformance =
      Path.join(
        System.tmp_dir!(),
        "conformance_inventory_#{System.unique_integer([:positive])}.term"
      )

    tmp_provenance =
      Path.join(
        System.tmp_dir!(),
        "provenance_inventory_#{System.unique_integer([:positive])}.term"
      )

    on_exit(fn ->
      try do
        File.rm(tmp_roster)
      rescue
        _ -> :ok
      end

      try do
        File.rm(tmp_spend)
      rescue
        _ -> :ok
      end

      try do
        File.rm(tmp_approvals)
      rescue
        _ -> :ok
      end

      try do
        File.rm(tmp_conformance)
      rescue
        _ -> :ok
      end

      try do
        File.rm(tmp_provenance)
      rescue
        _ -> :ok
      end
    end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})

    start_supervised!(
      {StateStore, name: "roster_trust", path: tmp_roster, initial: %{records: []}}
    )

    start_supervised!({StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})

    start_supervised!(
      {StateStore, name: "pending_approvals", path: tmp_approvals, initial: %{approvals: %{}}}
    )

    start_supervised!({StateStore, name: "conformance", path: tmp_conformance, initial: %{}})

    start_supervised!({StateStore, name: "provenance", path: tmp_provenance, initial: %{}})

    {:ok,
     tmp_roster: tmp_roster,
     tmp_spend: tmp_spend,
     tmp_approvals: tmp_approvals,
     tmp_conformance: tmp_conformance,
     tmp_provenance: tmp_provenance}
  end

  test "render/1 returns standing inventory text" do
    # Add a mock digest to RosterStore to check if inventory extracts it
    :ok =
      StateStore.apply_action(
        "roster_trust",
        {:append, :records, %{"digest" => "test digest text"}}
      )

    report = Inventory.render(manifest_path: "manifests/discovery.md")

    assert report =~ "Agent OS Standing Inventory"
    assert report =~ "PURPOSE: Surface high-signal"
    assert report =~ "CAPABILITIES:"
    assert report =~ "WRITE TO YOUR LOCAL STATE STORE"
    assert report =~ "SEND MESSAGES OUT TO EXTERNAL RECIPIENTS"
    refute report =~ "GRANTS:"
    assert report =~ "SPEND: $0.0 / $0.5 per daily"
    assert report =~ "Total Records: 1"
    assert report =~ "Last Digest: test digest text"
  end

  describe "spend visibility (User Story 3)" do
    test "renders spend from spend_ledger correctly and resets after rollover" do
      now = ~U[2026-06-29 12:00:00Z]

      # (a) seed spend_ledger with spent: 3
      :ok =
        StateStore.apply_action(
          "spend_ledger",
          {:put, "discovery", %{spent: 3, window_start: now}}
        )

      report_a = Inventory.render(manifest_path: "manifests/discovery.md", now: now)
      assert report_a =~ "SPEND: $0.000003 / $0.5 per daily"

      # (b) seed spent: 5, window_start: 25 hours ago -> resets to 0 on display
      past_time = DateTime.add(now, -25 * 3600, :second)

      :ok =
        StateStore.apply_action(
          "spend_ledger",
          {:put, "discovery", %{spent: 5, window_start: past_time}}
        )

      report_b = Inventory.render(manifest_path: "manifests/discovery.md", now: now)
      assert report_b =~ "SPEND: $0.0 / $0.5 per daily"
    end

    test "renders spend with empty ledger as 0" do
      now = ~U[2026-06-29 12:00:00Z]
      # empty ledger (discovery not present)
      report = Inventory.render(manifest_path: "manifests/discovery.md", now: now)
      assert report =~ "SPEND: $0.0 / $0.5 per daily"
    end
  end

  test "renders pending approvals on standing inventory" do
    mock_action = %AgentOS.ProposedAction{
      type: "external_send",
      recipient: "owner-inbox",
      method: "send",
      payload: %{"text" => "hello"}
    }

    mock_grant = %AgentOS.Manifest.Grant{
      connector: "external_send",
      recipients: ["owner-inbox"],
      methods: ["send"]
    }

    :ok =
      StateStore.apply_action(
        "pending_approvals",
        {:put, :approvals,
         %{"ref_42" => %{ref: "ref_42", action: mock_action, grant: mock_grant}}}
      )

    report = Inventory.render(manifest_path: "manifests/discovery.md")

    assert report =~ "Pending approvals:"
    assert report =~ "ref_42"
    assert report =~ "external_send → owner-inbox"
  end

  describe "conformance visibility" do
    alias AgentOS.ConformanceAuditor.Verdict
    alias AgentOS.ConformanceAuditor.Flag

    test "renders insufficient data when no verdict exists" do
      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "CONFORMANCE: insufficient data (0 runs recorded)"
    end

    test "renders CONFORMANCE: clean when persisted verdict is clean" do
      verdict = %Verdict{
        agent: "discovery",
        status: :clean,
        flags: [],
        computed_at: DateTime.utc_now()
      }

      :ok = StateStore.apply_action("conformance", {:put, "discovery", verdict})

      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "CONFORMANCE: clean"
    end

    test "renders CONFORMANCE: flagged with flags categorized by axis" do
      f1 = %Flag{
        type: :gate_breach,
        severity: :tripwire,
        description: "manifest-breach attempt recorded in last 20 runs"
      }

      f2 = %Flag{
        type: :denied_approval,
        severity: :count,
        description: "3 approval-required actions denied in window"
      }

      f3 = %Flag{type: :quiet, severity: :health, description: "no action in 3 consecutive runs"}

      verdict = %Verdict{
        agent: "discovery",
        status: :flagged,
        flags: [f1, f2, f3],
        computed_at: DateTime.utc_now()
      }

      :ok = StateStore.apply_action("conformance", {:put, "discovery", verdict})

      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "CONFORMANCE: flagged"
      assert report =~ "  [trust]  gate-breach — manifest-breach attempt recorded in last 20 runs"
      assert report =~ "  [trust]  denied-approval — 3 approval-required actions denied in window"
      assert report =~ "  [health] quiet — no action in 3 consecutive runs"
    end

    test "renders DEPLOY PROVENANCE from provenance StateStore" do
      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "DEPLOY PROVENANCE: unknown"

      :ok =
        StateStore.apply_action(
          "provenance",
          {:put, "discovery", %{status: :skipped_in_envelope, hash: "123"}}
        )

      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "DEPLOY PROVENANCE: skipped-in-envelope"

      :ok =
        StateStore.apply_action(
          "provenance",
          {:put, "discovery", %{status: :reviewed_human, hash: "123"}}
        )

      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "DEPLOY PROVENANCE: reviewed=human"
    end
  end

  describe "judge results visibility (Stage 3)" do
    test "renders JUDGE: unrun when no judge result is recorded" do
      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "JUDGE: unrun"
    end

    test "renders JUDGE: pass with last-run timestamp and disclaimer" do
      tmp_judge =
        Path.join(System.tmp_dir!(), "judge_inventory_#{System.unique_integer([:positive])}.term")

      on_exit(fn -> File.rm(tmp_judge) end)
      start_supervised!({StateStore, name: "judge_results", path: tmp_judge, initial: %{}})

      :ok =
        StateStore.apply_action(
          "judge_results",
          {:put, "discovery",
           %{status: :pass, last_run: ~U[2026-06-30 22:15:00Z], reasoning: "all checks passed"}}
        )

      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "JUDGE: pass (last run: 2026-06-30T22:15:00Z)"

      assert report =~
               "Scope: CODE-MATCHES-MANIFEST. This does not verify human intent correctness."
    end

    test "renders JUDGE: fail when the persisted verdict failed" do
      tmp_judge =
        Path.join(System.tmp_dir!(), "judge_inventory_#{System.unique_integer([:positive])}.term")

      on_exit(fn -> File.rm(tmp_judge) end)
      start_supervised!({StateStore, name: "judge_results", path: tmp_judge, initial: %{}})

      :ok =
        StateStore.apply_action(
          "judge_results",
          {:put, "discovery",
           %{status: :fail, last_run: ~U[2026-06-30 22:15:00Z], reasoning: "x"}}
        )

      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "JUDGE: fail (last run: 2026-06-30T22:15:00Z)"
    end
  end

  describe "security review results visibility (Stage 5)" do
    test "renders SECURITY REVIEW: unrun when no security review is recorded" do
      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "SECURITY REVIEW: unrun"
    end

    test "renders SECURITY REVIEW: pass with timestamp, reasoning, and disclaimer" do
      tmp_review =
        Path.join(
          System.tmp_dir!(),
          "review_inventory_#{System.unique_integer([:positive])}.term"
        )

      on_exit(fn -> File.rm(tmp_review) end)

      start_supervised!(
        {StateStore, name: "security_review_results", path: tmp_review, initial: %{}}
      )

      :ok =
        StateStore.apply_action(
          "security_review_results",
          {:put, "discovery",
           %{status: :pass, timestamp: ~U[2026-06-30 22:15:00Z], reasoning: "code looks safe"}}
        )

      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "SECURITY REVIEW: pass (reviewed at: 2026-06-30T22:15:00Z)"
      assert report =~ "Reasoning: code looks safe"
      assert report =~ "Disclaimer: Security review is a probabilistic LLM smoke detector."
    end

    test "renders SECURITY REVIEW: fail when the review failed" do
      tmp_review =
        Path.join(
          System.tmp_dir!(),
          "review_inventory_#{System.unique_integer([:positive])}.term"
        )

      on_exit(fn -> File.rm(tmp_review) end)

      start_supervised!(
        {StateStore, name: "security_review_results", path: tmp_review, initial: %{}}
      )

      :ok =
        StateStore.apply_action(
          "security_review_results",
          {:put, "discovery",
           %{status: :fail, timestamp: ~U[2026-06-30 22:15:00Z], reasoning: "dangerous connector"}}
        )

      report = Inventory.render(manifest_path: "manifests/discovery.md")
      assert report =~ "SECURITY REVIEW: fail (reviewed at: 2026-06-30T22:15:00Z)"
      assert report =~ "Reasoning: dangerous connector"
    end
  end
end
