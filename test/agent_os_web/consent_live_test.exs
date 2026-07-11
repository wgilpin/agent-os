defmodule AgentOSWeb.ConsentLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint AgentOSWeb.Endpoint

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "consent_live_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    tmp_pending = Path.join(tmp_dir, "pending_approvals.db")
    tmp_provenance = Path.join(tmp_dir, "provenance.db")
    tmp_judge = Path.join(tmp_dir, "judge.db")
    tmp_security = Path.join(tmp_dir, "security.db")

    # Start prerequisite systems manually in isolation
    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})

    start_supervised!(
      {AgentOS.StateStore,
       name: "pending_approvals", path: tmp_pending, initial: %{approvals: %{}}}
    )

    start_supervised!(
      {AgentOS.StateStore, name: "provenance", path: tmp_provenance, initial: %{}}
    )

    start_supervised!({AgentOS.StateStore, name: "judge_results", path: tmp_judge, initial: %{}})

    start_supervised!(
      {AgentOS.StateStore, name: "security_review_results", path: tmp_security, initial: %{}}
    )

    # Approval-resume for deploy-shaped actions writes the deployment registry (041).
    tmp_deployments = Path.join(tmp_dir, "deployments.db")

    start_supervised!(
      {AgentOS.StateStore, name: "deployments", path: tmp_deployments, initial: %{}}
    )

    start_supervised!({Phoenix.PubSub, name: AgentOS.PubSub})
    start_supervised!(AgentOS.TriggerGateway)
    start_supervised!({AgentOS.RunSupervisor, [worker_fn: fn _opts -> :ok end]})
    start_supervised!(AgentOSWeb.Endpoint)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, conn: build_conn()}
  end

  test "renders all capability grants, spend cap, and badge details correctly", %{
    tmp_dir: tmp_dir,
    conn: conn
  } do
    manifest_path = Path.join(tmp_dir, "my_agent.md")

    File.write!(manifest_path, """
    ---
    purpose: "verify deterministic consent display"
    grants:
      - connector: kv_append
        methods: ["append"]
      - connector: external_send
        recipients: ["owner-inbox"]
        methods: ["send"]
      - connector: gmail_read
    spend:
      cap: 150000
      window: daily
      on_breach: kill
    owner: human
    supervision: restart-once-and-alert
    ---
    # My agent
    """)

    assert {:ok, _lv, html} = live(conn, "/consent?manifest=#{manifest_path}")

    # Assert purpose
    assert html =~ "verify deterministic consent display"

    # Assert exact phrases
    assert html =~ "Write to your local state store"
    assert html =~ "Send messages out to external recipients"
    assert html =~ "Read incoming emails from Gmail"

    # Assert scoping values
    assert html =~ "append"
    assert html =~ "owner-inbox"
    assert html =~ "send"

    # Assert danger badges (external, local, read_only)
    assert html =~ "danger-badge-external"
    assert html =~ "danger-badge-local"
    assert html =~ "danger-badge-read_only"

    # Assert spend cap representation
    assert html =~ "$0.15"
  end

  test "approve unblocks deployment, records provenance and TriggerGateway approval", %{
    tmp_dir: tmp_dir,
    conn: conn
  } do
    manifest_path = Path.join(tmp_dir, "test_agent.md")

    File.write!(manifest_path, """
    ---
    purpose: "testing approval transition"
    grants:
      - connector: kv_append
        methods: ["append"]
    spend:
      cap: 100000
      window: daily
      on_breach: kill
    owner: human
    supervision: restart-once-and-alert
    ---
    """)

    # Seed a pending deploy approval
    ref = "ref_deploy_test_agent_1"

    action = %AgentOS.ProposedAction{
      type: "deploy",
      recipient: "test_agent",
      method: manifest_path,
      payload: %{"hash" => "HASH123"}
    }

    grant = %AgentOS.Manifest.Grant{connector: "deploy"}

    :ok =
      AgentOS.StateStore.apply_action(
        "pending_approvals",
        {:put, :approvals, %{ref => %{ref: ref, action: action, grant: grant}}}
      )

    # Access the LiveView
    assert {:ok, lv, html} = live(conn, "/consent?manifest=#{manifest_path}")
    assert html =~ "Approve"

    # Click Approve
    html_approved = lv |> element(".btn-approve") |> render_click()
    assert html_approved =~ "The agent is being deployed"

    # Verify provenance is updated to :reviewed_human
    provenance = AgentOS.StateStore.snapshot("provenance")
    assert %{status: :reviewed_human} = Map.get(provenance, "test_agent")

    # Verify pending approvals deletes the ref
    pending = AgentOS.StateStore.snapshot("pending_approvals")
    approvals = Map.get(pending, :approvals, %{})
    refute Map.has_key?(approvals, ref)
  end

  test "approve is refused by the deploy gate when machine verdicts are not green", %{
    tmp_dir: tmp_dir,
    conn: conn
  } do
    # The test env runs :dangerously_skip_review; force the real gate for this test.
    original_mode = Application.get_env(:agent_os, :review_mode)
    Application.put_env(:agent_os, :review_mode, :always_review)

    on_exit(fn ->
      if original_mode,
        do: Application.put_env(:agent_os, :review_mode, original_mode),
        else: Application.delete_env(:agent_os, :review_mode)
    end)

    manifest_path = Path.join(tmp_dir, "ungated_agent.md")

    File.write!(manifest_path, """
    ---
    purpose: "testing approval gate"
    grants:
      - connector: kv_append
        methods: ["append"]
    spend:
      cap: 100000
      window: daily
      on_breach: kill
    owner: human
    supervision: restart-once-and-alert
    ---
    """)

    ref = "ref_deploy_ungated_agent_1"

    action = %AgentOS.ProposedAction{
      type: "deploy",
      recipient: "ungated_agent",
      method: manifest_path,
      payload: %{"hash" => "HASH123"}
    }

    grant = %AgentOS.Manifest.Grant{connector: "deploy"}

    :ok =
      AgentOS.StateStore.apply_action(
        "pending_approvals",
        {:put, :approvals, %{ref => %{ref: ref, action: action, grant: grant}}}
      )

    assert {:ok, lv, _html} = live(conn, "/consent?manifest=#{manifest_path}")

    # No judge/security verdicts exist for this agent: approval must be refused.
    html = lv |> element(".btn-approve") |> render_click()
    refute html =~ "The agent is being deployed"
    assert html =~ "Not approved:"

    # Provenance must NOT say a human review happened.
    provenance = AgentOS.StateStore.snapshot("provenance")
    refute match?(%{status: :reviewed_human}, Map.get(provenance, "ungated_agent"))

    # The pending ref survives so the decision can be made after a re-run.
    pending = AgentOS.StateStore.snapshot("pending_approvals")
    assert Map.has_key?(Map.get(pending, :approvals, %{}), ref)
  end

  test "reject blocks deploy, cancels pending approval ref, and leaves agent code unexecuted", %{
    tmp_dir: tmp_dir,
    conn: conn
  } do
    manifest_path = Path.join(tmp_dir, "reject_agent.md")

    File.write!(manifest_path, """
    ---
    purpose: "testing reject transition"
    grants:
      - connector: kv_append
        methods: ["append"]
    spend:
      cap: 100000
      window: daily
      on_breach: kill
    owner: human
    supervision: restart-once-and-alert
    ---
    """)

    # Seed a pending deploy approval
    ref = "ref_deploy_reject_agent_1"

    action = %AgentOS.ProposedAction{
      type: "deploy",
      recipient: "reject_agent",
      method: manifest_path,
      payload: %{"hash" => "HASH987"}
    }

    grant = %AgentOS.Manifest.Grant{connector: "deploy"}

    :ok =
      AgentOS.StateStore.apply_action(
        "pending_approvals",
        {:put, :approvals, %{ref => %{ref: ref, action: action, grant: grant}}}
      )

    # Access the LiveView
    assert {:ok, lv, html} = live(conn, "/consent?manifest=#{manifest_path}")
    assert html =~ "Reject"

    # Click Reject
    html_rejected = lv |> element(".btn-reject") |> render_click()
    assert html_rejected =~ "will not be deployed or run"

    # Verify provenance is NOT reviewed_human (should not be present or different status)
    provenance = AgentOS.StateStore.snapshot("provenance")
    refute Map.has_key?(provenance, "reject_agent")

    # Verify pending approvals deletes the ref
    pending = AgentOS.StateStore.snapshot("pending_approvals")
    approvals = Map.get(pending, :approvals, %{})
    refute Map.has_key?(approvals, ref)
  end

  test "gate refusal offers the re-run remedy for an agent WITH code (FR-006)", %{
    tmp_dir: tmp_dir,
    conn: conn
  } do
    original_mode = Application.get_env(:agent_os, :review_mode)
    Application.put_env(:agent_os, :review_mode, :always_review)

    manifest_path = Path.join(tmp_dir, "coded_consent.md")

    File.write!(manifest_path, """
    ---
    purpose: "re-run remedy for coded agent"
    grants:
      - connector: kv_append
        methods: ["append"]
    spend:
      cap: 100000
      window: daily
      on_breach: kill
    owner: human
    supervision: restart-once-and-alert
    ---
    """)

    # The consent view checks code presence against the real agents/<name>/main.py.
    File.mkdir_p!("agents/coded_consent")
    File.write!("agents/coded_consent/main.py", "print('x')")

    on_exit(fn ->
      if original_mode,
        do: Application.put_env(:agent_os, :review_mode, original_mode),
        else: Application.delete_env(:agent_os, :review_mode)

      File.rm_rf!("agents/coded_consent")
    end)

    assert {:ok, lv, _html} = live(conn, "/consent?manifest=#{manifest_path}")
    html = lv |> element(".btn-approve") |> render_click()

    assert html =~ "Not approved:"
    assert html =~ "Re-run its checks from the inventory."
    assert html =~ ~s(href="/inventory")
  end

  test "gate refusal directs an orphan (no code) to re-create or delete (FR-006)", %{
    tmp_dir: tmp_dir,
    conn: conn
  } do
    original_mode = Application.get_env(:agent_os, :review_mode)
    Application.put_env(:agent_os, :review_mode, :always_review)

    on_exit(fn ->
      if original_mode,
        do: Application.put_env(:agent_os, :review_mode, original_mode),
        else: Application.delete_env(:agent_os, :review_mode)
    end)

    manifest_path = Path.join(tmp_dir, "orphan_consent.md")

    File.write!(manifest_path, """
    ---
    purpose: "re-run remedy for orphan agent"
    grants:
      - connector: kv_append
        methods: ["append"]
    spend:
      cap: 100000
      window: daily
      on_breach: kill
    owner: human
    supervision: restart-once-and-alert
    ---
    """)

    # No agents/orphan_consent/main.py exists → code_missing is true.
    assert {:ok, lv, _html} = live(conn, "/consent?manifest=#{manifest_path}")
    html = lv |> element(".btn-approve") |> render_click()

    assert html =~ "Not approved:"
    assert html =~ "Re-create it from the Create agent page, or delete it"
    refute html =~ "Re-run its checks from the inventory."
  end

  test "surfaces connector registration lookup loud-failure error on missing registry connector",
       %{tmp_dir: tmp_dir, conn: conn} do
    # Temporarily override connector registry to simulate a missing connector
    original_registry = Application.get_env(:agent_os, :connector_registry)

    # Put a registry without "gmail_read"
    Application.put_env(:agent_os, :connector_registry, %{
      "kv_append" => %{
        name: "kv_append",
        mutating?: true,
        requires_deploy_consent?: false,
        requires_runtime_approval?: false,
        credential: nil,
        cost: 0
      }
    })

    on_exit(fn ->
      if original_registry do
        Application.put_env(:agent_os, :connector_registry, original_registry)
      else
        Application.delete_env(:agent_os, :connector_registry)
      end
    end)

    manifest_path = Path.join(tmp_dir, "missing_connector_agent.md")

    # This manifest references "gmail_read" which is missing from the registry override
    File.write!(manifest_path, """
    ---
    purpose: "verify unregistered connector error path"
    grants:
      - connector: gmail_read
    spend:
      cap: 100000
      window: daily
      on_breach: kill
    owner: human
    supervision: restart-once-and-alert
    ---
    """)

    # When accessing the LiveView, it should load and fail loudly, displaying the registry lookup exception
    assert {:ok, _lv, html} = live(conn, "/consent?manifest=#{manifest_path}")

    assert html =~ "Capability Loading Error"
    assert html =~ "missing" or html =~ "Unknown connector"
  end
end
