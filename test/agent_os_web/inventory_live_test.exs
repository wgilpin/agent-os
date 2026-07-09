defmodule AgentOSWeb.InventoryLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias AgentOS.StateStore

  @endpoint AgentOSWeb.Endpoint

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "inventory_live_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    tmp_roster = Path.join(tmp_dir, "roster.db")
    tmp_spend = Path.join(tmp_dir, "spend.db")
    tmp_pending = Path.join(tmp_dir, "pending.db")
    tmp_conformance = Path.join(tmp_dir, "conformance.db")
    tmp_provenance = Path.join(tmp_dir, "provenance.db")
    tmp_judge = Path.join(tmp_dir, "judge.db")
    tmp_security = Path.join(tmp_dir, "security.db")

    # Start prerequisite systems manually in isolation
    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})

    start_supervised!(
      {StateStore, name: "roster_trust", path: tmp_roster, initial: %{records: []}}
    )

    start_supervised!({StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})

    start_supervised!(
      {StateStore, name: "pending_approvals", path: tmp_pending, initial: %{approvals: %{}}}
    )

    start_supervised!({StateStore, name: "conformance", path: tmp_conformance, initial: %{}})
    start_supervised!({StateStore, name: "provenance", path: tmp_provenance, initial: %{}})
    start_supervised!({StateStore, name: "judge_results", path: tmp_judge, initial: %{}})

    start_supervised!(
      {StateStore, name: "security_review_results", path: tmp_security, initial: %{}}
    )

    start_supervised!(
      {StateStore, name: "deployments", path: Path.join(tmp_dir, "deployments.db"), initial: %{}}
    )

    start_supervised!({Phoenix.PubSub, name: AgentOS.PubSub})
    start_supervised!(AgentOSWeb.Endpoint)

    # The discovery manifest is a test fixture (it no longer lives under manifests/,
    # so it never shows in the real inventory). These UI tests assert against its
    # card, so surface it in the scanned dir for the duration of the test.
    File.cp!("test/fixtures/manifests/discovery.md", "manifests/discovery.md")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      File.rm("manifests/temp_test_agent.md")
      File.rm("manifests/discovery.md")
    end)

    {:ok, tmp_dir: tmp_dir, conn: build_conn()}
  end

  test "renders active agent roster, spend, and audit logs correctly", %{conn: conn} do
    # Visit /inventory
    assert {:ok, _lv, html} = live(conn, "/inventory")

    # Assert the discovery fixture agent is shown
    assert html =~ "agent-card-discovery"
    assert html =~ "discovery"
    assert html =~ "Surface high-signal"
    assert html =~ "daily"

    # Seed a second manifest
    File.write!("manifests/temp_test_agent.md", """
    ---
    purpose: "Testing dynamic agent roster enumeration"
    triggers:
      - type: message
    grants:
      - connector: kv_append
    mounts: []
    spend:
      cap: 200000
      window: daily
      on_breach: kill
    owner: human
    supervision: restart-once-and-alert
    ---
    """)

    # Reload the page to assert both agents render
    assert {:ok, _lv2, html2} = live(conn, "/inventory")
    assert html2 =~ "discovery"
    assert html2 =~ "temp_test_agent"
    assert html2 =~ "Testing dynamic agent roster"
  end

  test "renders spend warnings and breach alerts", %{conn: conn} do
    # Seed spend near cap (e.g. 450,000 / 500,000)
    now = DateTime.utc_now()

    :ok =
      StateStore.apply_action(
        "spend_ledger",
        {:put, "discovery", %{spent: 450_000, window_start: now}}
      )

    assert {:ok, _lv, html} = live(conn, "/inventory")
    assert html =~ "spend-warning" or html =~ "WARNING"

    # Seed spend over cap (e.g. 550,000 / 500,000)
    :ok =
      StateStore.apply_action(
        "spend_ledger",
        {:put, "discovery", %{spent: 550_000, window_start: now}}
      )

    assert {:ok, _lv2, html2} = live(conn, "/inventory")
    assert html2 =~ "spend-breached" or html2 =~ "BREACH"
  end

  test "renders audit log run records, conformance flags, and pending approvals", %{conn: conn} do
    # Write a mock record to the (test-env, tmp) run log. The record must carry
    # agent= — each card shows only its own runs.
    run_log_path = AgentOS.RunLog.default_path()
    backup = if File.exists?(run_log_path), do: File.read!(run_log_path), else: nil

    File.write!(run_log_path, """
    - [2026-07-01T20:00:00Z] status=ok actions=3 agent=discovery trigger=timer items_in=10 items_dropped=2 note=Run completed successfully
    """)

    # Seed conformance flag
    flag = %AgentOS.ConformanceAuditor.Flag{
      type: :gate_breach,
      severity: :tripwire,
      description: "manifest-breach attempt detected"
    }

    verdict = %AgentOS.ConformanceAuditor.Verdict{
      agent: "discovery",
      status: :flagged,
      flags: [flag],
      computed_at: DateTime.utc_now()
    }

    :ok = StateStore.apply_action("conformance", {:put, "discovery", verdict})

    # Seed pending approval
    ref = "ref_approval_test_1"

    action = %AgentOS.ProposedAction{
      type: "external_send",
      recipient: "owner-inbox",
      method: "send",
      payload: %{}
    }

    grant = %AgentOS.Manifest.Grant{connector: "external_send"}

    :ok =
      StateStore.apply_action(
        "pending_approvals",
        {:put, :approvals, %{ref => %{ref: ref, action: action, grant: grant}}}
      )

    try do
      assert {:ok, _lv, html} = live(conn, "/inventory")
      assert html =~ "Run completed successfully"
      assert html =~ "manifest-breach attempt detected"
      assert html =~ "ref_approval_test_1"
    after
      if backup do
        File.write!(run_log_path, backup)
      else
        File.rm(run_log_path)
      end
    end
  end

  test "polls for changes and updates on tick", %{conn: conn} do
    assert {:ok, lv, html} = live(conn, "/inventory")
    refute html =~ "updated_purpose"

    # Seed a new manifest with "updated_purpose"
    File.write!("manifests/temp_test_agent.md", """
    ---
    purpose: "updated_purpose"
    triggers: []
    grants: []
    mounts: []
    spend:
      cap: 100000
      window: daily
      on_breach: kill
    owner: human
    supervision: restart-once
    ---
    """)

    # Trigger tick
    send(lv.pid, :tick)
    html2 = render(lv)
    assert html2 =~ "updated_purpose"
  end

  test "delete requires an explicit confirmation step", %{conn: conn} do
    File.write!("manifests/temp_test_agent.md", """
    ---
    purpose: "Agent slated for deletion"
    triggers: []
    grants: []
    mounts: []
    spend:
      cap: 100000
      window: daily
      on_breach: kill
    owner: human
    supervision: restart-once
    ---
    """)

    assert {:ok, lv, _html} = live(conn, "/inventory")
    card = "#agent-card-temp_test_agent"

    # First click opens the server-rendered confirmation; nothing is deleted yet.
    html = lv |> element("#{card} .btn-delete") |> render_click()
    assert html =~ "delete-confirm"
    assert html =~ "cannot be undone"
    assert File.exists?("manifests/temp_test_agent.md")

    # Cancel closes the confirmation without deleting.
    html = lv |> element("#{card} .btn-cancel-delete") |> render_click()
    refute html =~ "delete-confirm"
    assert File.exists?("manifests/temp_test_agent.md")

    # Re-open and confirm: only now does the agent actually go away.
    lv |> element("#{card} .btn-delete") |> render_click()
    html = lv |> element("#{card} .btn-confirm-delete") |> render_click()
    refute html =~ "agent-card-temp_test_agent"
    refute File.exists?("manifests/temp_test_agent.md")
  end
end
