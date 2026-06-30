defmodule AgentOS.ElicitationTest do
  use ExUnit.Case, async: false

  alias AgentOS.ElicitationSession

  setup do
    # Enable mock elicitor behavior for child processes
    System.put_env("MOCK_ELICITOR", "true")

    on_exit(fn ->
      System.delete_env("MOCK_ELICITOR")
    end)

    :ok
  end

  test "happy path conversation flow" do
    # 1. Start the session with initial purpose
    assert {:ok, pid} = ElicitationSession.start_link("reply to recruiter emails")

    # Initial state should have assistant question
    session = ElicitationSession.get_state(pid)
    assert length(session.transcript) == 2
    assert session.status == :active
    assert session.spec_draft.purpose == "reply to recruiter emails"

    # Last message should be the first question
    last_msg = List.last(session.transcript)
    assert last_msg.role == :assistant
    assert last_msg.content == "Which email service do you use? (e.g. Gmail)"

    # 2. User responds with Gmail
    assert {:ok, session2, next_q, creep, _pb} = ElicitationSession.submit_message(pid, "Gmail")
    refute creep
    assert "gmail_read" in session2.spec_draft.capabilities
    assert next_q == "Should the agent send emails directly or just save drafts?"

    # 3. User responds with save drafts
    assert {:ok, session3, next_q3, creep3, _pb3} =
             ElicitationSession.submit_message(pid, "save drafts")

    refute creep3
    assert "gmail_draft" in session3.spec_draft.capabilities
    assert next_q3 == "Do you confirm this minimised specification?"

    # 4. User confirms with yes
    assert {:ok, session4, next_q4, _, _} = ElicitationSession.submit_message(pid, "yes")
    assert session4.status == :confirmed
    assert session4.spec_draft.confirmed
    assert next_q4 == ""

    # 5. Write the spec to a temp directory inside workspace
    temp_dir = Path.join(["data", "test_elicitation"])
    File.mkdir_p!(temp_dir)
    assert :ok = ElicitationSession.write_spec(pid, temp_dir)

    # Verify elicited_spec.json exists and is valid
    spec_path = Path.join(temp_dir, "elicited_spec.json")
    assert File.exists?(spec_path)
    {:ok, spec_body} = File.read(spec_path)
    assert {:ok, spec_data} = Jason.decode(spec_body)
    assert spec_data["confirmed"] == true
    assert spec_data["purpose"] == "reply to recruiter emails and save drafts"
    assert spec_data["capabilities"] == ["gmail_read", "gmail_draft"]

    # Cleanup temp dir
    File.rm_rf!(temp_dir)
  end

  test "scope creep detection flow" do
    assert {:ok, pid} = ElicitationSession.start_link("reply to recruiter emails")

    # User inputs a response that includes delete capability
    assert {:ok, session, next_q, creep, pushback} =
             ElicitationSession.submit_message(pid, "delete recruiter emails")

    assert creep
    assert pushback =~ "Warning: Deleting emails was requested, but is not needed"
    assert next_q == "Do you confirm this minimised specification?"
    refute "gmail_delete" in session.spec_draft.capabilities
  end
end
