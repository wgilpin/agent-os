defmodule AgentOSWeb.ElicitationLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint AgentOSWeb.Endpoint

  setup do
    # Enable mock elicitor behavior for child processes
    System.put_env("MOCK_ELICITOR", "true")

    tmp_spend =
      Path.join(
        System.tmp_dir!(),
        "spend_ledger_lv_test_#{System.unique_integer([:positive])}.db"
      )

    # Start prerequisite systems for this test block
    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({AgentOS.StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})
    start_supervised!(AgentOS.CredentialProxy)
    start_supervised!(AgentOS.InferenceBroker)
    start_supervised!({Phoenix.PubSub, name: AgentOS.PubSub})
    start_supervised!(AgentOSWeb.Endpoint)

    on_exit(fn ->
      System.delete_env("MOCK_ELICITOR")
      File.rm(tmp_spend)
    end)

    {:ok, conn: build_conn()}
  end

  test "complete interactive elicitation flow via LiveView", %{conn: conn} do
    # 1. Access root page and assert landing state
    assert {:ok, lv, html} = live(conn, "/")
    assert html =~ "Agent OS Elicitor"
    assert html =~ "Define one agent with one clear purpose"

    # 2. Submit initial purpose form to start the session
    assert html2 =
             lv
             |> form(".landing-form", %{purpose: "reply to recruiter emails"})
             |> render_submit()

    # The view should transition to the conversational workspace
    assert html2 =~ "Elicitation Workspace"
    assert html2 =~ "Which email service do you use?"

    # The Live Spec sidebar should display the initial purpose draft
    assert html2 =~ "reply to recruiter emails"

    # 3. Enter first conversational turn ("Gmail")
    assert html3 =
             lv
             |> form(".input-form", %{message: "Gmail"})
             |> render_submit()

    assert html3 =~ "Gmail"
    assert html3 =~ "Should the agent send emails directly or just save drafts?"
    assert html3 =~ "gmail_read"

    # 4. Trigger scope creep warning
    assert html4 =
             lv
             |> form(".input-form", %{message: "delete recruiter emails"})
             |> render_submit()

    assert html4 =~ "[KISS Check Warning]"
    assert html4 =~ "Warning: Deleting emails was requested, but is not needed"

    # 5. Answer next prompt to reach confirmed state
    assert html5 =
             lv
             |> form(".input-form", %{message: "save drafts"})
             |> render_submit()

    assert html5 =~ "Do you confirm this minimised specification?"

    # Respond with "yes" to trigger confirmed spec card
    assert html6 =
             lv
             |> form(".input-form", %{message: "yes"})
             |> render_submit()

    assert html6 =~ "Confirm Elicited Specification?"

    # 6. Test refine flow
    assert html_refine = lv |> element(".btn-refine") |> render_click()
    refute html_refine =~ "Confirm Elicited Specification?"
    assert html_refine =~ "How should we adjust the specification?"

    # Go back to confirm state again
    lv |> form(".input-form", %{message: "yes"}) |> render_submit()

    # 7. Confirm spec writing
    temp_dir = Path.join(["data", "test_elicitation_lv"])
    File.mkdir_p!(temp_dir)

    # We mock write_spec target_dir inside the LiveView test execution path if possible.
    # To test write_spec cleanly, let's trigger confirm_spec event.
    # Wait, the confirm_spec handler writes to "specs/012-elicit-spec".
    # Let's back up existing elicited_spec.json if it exists to avoid overwriting developers' local files.
    backup_path = "specs/012-elicit-spec/elicited_spec.json.bak"
    real_path = "specs/012-elicit-spec/elicited_spec.json"

    if File.exists?(real_path), do: File.cp!(real_path, backup_path)

    try do
      assert html_success = lv |> element(".btn-confirm") |> render_click()
      assert html_success =~ "Specification Confirmed!"
      assert html_success =~ "written successfully"

      # Verify file was written
      assert File.exists?(real_path)
      {:ok, spec_body} = File.read(real_path)
      assert {:ok, spec_data} = Jason.decode(spec_body)
      assert spec_data["confirmed"] == true
      assert spec_data["purpose"] =~ "reply to recruiter emails"
    after
      # Restore backup
      if File.exists?(backup_path) do
        File.cp!(backup_path, real_path)
        File.rm!(backup_path)
      else
        File.rm(real_path)
      end
    end
  end
end
