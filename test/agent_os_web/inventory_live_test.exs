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

  test "shows 'Re-run checks' only for agents with generated code (spec 043)", %{conn: conn} do
    # Orphan: manifest, no code → no button.
    File.write!("manifests/temp_test_agent.md", """
    ---
    purpose: "orphan with no code"
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

    # Coded agent: manifest + generated code → button present.
    File.write!("manifests/coded_agent.md", """
    ---
    purpose: "agent with generated code"
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

    File.mkdir_p!("agents/coded_agent")
    File.write!("agents/coded_agent/main.py", "print('x')")
    File.write!("agents/coded_agent/models.py", "x = 1")

    on_exit(fn ->
      File.rm("manifests/coded_agent.md")
      File.rm_rf!("agents/coded_agent")
    end)

    assert {:ok, lv, _html} = live(conn, "/inventory")

    assert has_element?(lv, "#agent-card-coded_agent .btn-rerun-checks")
    refute has_element?(lv, "#agent-card-temp_test_agent .btn-rerun-checks")

    # Green agent: both verdicts pass for the CURRENT code → the recovery button
    # disappears (a re-run would be a paid no-op).
    hash = AgentOS.Provisioner.code_hash("coded_agent", [])

    :ok =
      StateStore.apply_action(
        "judge_results",
        {:put, "coded_agent", %{status: :pass, code_hash: hash}}
      )

    :ok =
      StateStore.apply_action(
        "security_review_results",
        {:put, "coded_agent",
         %AgentOS.Pipeline.Stage5.Verdict{
           status: :pass,
           reasoning: "ok",
           timestamp: DateTime.utc_now(),
           code_hash: hash
         }}
      )

    assert {:ok, lv2, _html} = live(conn, "/inventory")
    refute has_element?(lv2, "#agent-card-coded_agent .btn-rerun-checks")
  end

  test "a re-run refused as busy surfaces the 'already running' copy (FR-009)", %{conn: conn} do
    start_supervised!(AgentOS.Pipeline.RunLock)

    File.write!("manifests/coded_agent.md", """
    ---
    purpose: "agent with generated code"
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

    File.mkdir_p!("agents/coded_agent")
    File.write!("agents/coded_agent/main.py", "print('x')")
    File.write!("agents/coded_agent/models.py", "x = 1")

    on_exit(fn ->
      File.rm("manifests/coded_agent.md")
      File.rm_rf!("agents/coded_agent")
    end)

    # Simulate an in-flight run for this agent so the click is refused.
    :ok = AgentOS.Pipeline.RunLock.claim("coded_agent")

    assert {:ok, lv, _html} = live(conn, "/inventory")
    html = lv |> element("#agent-card-coded_agent .btn-rerun-checks") |> render_click()

    assert html =~ "a check is already running for this agent"
  end

  test "the 'Checks re-running' note clears on the rerun's terminal event", %{conn: conn} do
    start_supervised!(AgentOS.Pipeline.RunLock)

    File.write!("manifests/coded_agent.md", """
    ---
    purpose: "agent with generated code"
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

    File.mkdir_p!("agents/coded_agent")
    File.write!("agents/coded_agent/main.py", "print('x')")
    File.write!("agents/coded_agent/models.py", "x = 1")

    # The click must not spawn a real checks task: stub the runner via the config seam.
    Application.put_env(:agent_os, :rerun_default_opts,
      runner_fn: fn _agent, _run_id, _opts -> :ok end
    )

    on_exit(fn ->
      Application.delete_env(:agent_os, :rerun_default_opts)
      File.rm("manifests/coded_agent.md")
      File.rm_rf!("agents/coded_agent")
    end)

    assert {:ok, lv, _html} = live(conn, "/inventory")

    html = lv |> element("#agent-card-coded_agent .btn-rerun-checks") |> render_click()
    assert html =~ "Checks re-running"

    # A per-check event must NOT clear the note...
    send(
      lv.pid,
      {:pipeline_progress,
       %AgentOS.Pipeline.ProgressEvent{
         run_id: "rerun_1",
         agent_name: "coded_agent",
         stage: :judge,
         status: :finished,
         at: DateTime.utc_now()
       }}
    )

    assert render(lv) =~ "Checks re-running"

    # ...but the terminal event (stage :pipeline, as Rerun emits on completion) must.
    send(
      lv.pid,
      {:pipeline_progress,
       %AgentOS.Pipeline.ProgressEvent{
         run_id: "rerun_1",
         agent_name: "coded_agent",
         stage: :pipeline,
         status: :passed,
         at: DateTime.utc_now()
       }}
    )

    refute render(lv) =~ "Checks re-running"
  end

  test "startup triggers render as a readable pill, not a raw map", %{conn: conn} do
    File.write!("manifests/temp_test_agent.md", """
    ---
    purpose: "startup trigger rendering"
    triggers:
      - type: startup
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

    assert {:ok, _lv, html} = live(conn, "/inventory")
    assert html =~ "On startup"
    refute html =~ "%{type:"
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
