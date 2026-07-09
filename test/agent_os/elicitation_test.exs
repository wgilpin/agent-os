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

  test "confirmed flag with non-empty closing prose still confirms the session" do
    # Regression: live models set confirmed=true but close with prose ("Spec
    # confirmed. No further questions."). The session must key on the structured
    # flag, never on the next_question being empty.
    assert {:ok, pid} = ElicitationSession.start_link("reply to recruiter emails")

    assert {:ok, session, next_q, _creep, _pb} =
             ElicitationSession.submit_message(pid, "confirm")

    assert next_q == "Spec confirmed. No further questions."
    assert session.spec_draft.confirmed
    assert session.status == :confirmed

    # write_spec is unlocked by the confirmed status
    temp_dir = Path.join(["data", "test_elicitation_prose"])
    File.mkdir_p!(temp_dir)
    assert :ok = ElicitationSession.write_spec(pid, temp_dir)
    File.rm_rf!(temp_dir)
  end

  test "UI dollar cap overrides the elicited draft and lands in the written spec" do
    # The cap is a UI control (default $0.10), never an elicitation question —
    # the UI value is authoritative over whatever the elicitor drafted (0.05 here).
    assert {:ok, pid} = ElicitationSession.start_link("reply to recruiter emails")
    assert {:ok, session, _, _, _} = ElicitationSession.submit_message(pid, "yes")
    assert session.status == :confirmed
    assert session.spec_draft.spend_limits.dollar_cap == 0.05

    assert :ok = ElicitationSession.set_dollar_cap(pid, 0.10)

    temp_dir = Path.join(["data", "test_elicitation_cap"])
    File.mkdir_p!(temp_dir)
    assert :ok = ElicitationSession.write_spec(pid, temp_dir)

    {:ok, body} = File.read(Path.join(temp_dir, "elicited_spec.json"))
    assert {:ok, %{"spend_limits" => %{"dollar_cap" => 0.1}}} = Jason.decode(body)
    File.rm_rf!(temp_dir)
  end

  test "capability vocabulary exposes exactly the registry's ids" do
    # The elicitor receives this list so it can never invent capability ids
    # (observed live: 'Discord.send_message' → rejected at manifest projection).
    vocabulary = ElicitationSession.capability_vocabulary()
    ids = Enum.map(vocabulary, & &1["id"])

    assert Enum.sort(ids) == Enum.sort(Map.keys(AgentOS.Connector.registry()))
    assert "discord_notify" in ids
    assert Enum.all?(vocabulary, fn %{"description" => d} -> is_binary(d) and d != "" end)
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

  test "live UDS transport elicitation with spend metering and cap enforcement" do
    # Setup temporary environment
    System.delete_env("MOCK_ELICITOR")
    original_inf_path = Application.get_env(:agent_os, :inference_uds_path)
    original_autostart = Application.get_env(:agent_os, :autostart)

    tmp_dir =
      Path.join(System.tmp_dir!(), "elicitation_test_dir_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    tmp_socket = Path.join(tmp_dir, "inference.sock")

    Application.put_env(:agent_os, :inference_uds_path, tmp_socket)
    Application.put_env(:agent_os, :autostart, true)

    tmp_spend =
      Path.join(
        System.tmp_dir!(),
        "spend_ledger_elicit_test_#{System.unique_integer([:positive])}.db"
      )

    # Set up registry and state store
    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({AgentOS.StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})
    start_supervised!(AgentOS.CredentialProxy)
    start_supervised!(AgentOS.InferenceBroker)

    on_exit(fn ->
      File.rm(tmp_spend)
      File.rm_rf(tmp_dir)

      if original_inf_path,
        do: Application.put_env(:agent_os, :inference_uds_path, original_inf_path)

      if original_autostart != nil,
        do: Application.put_env(:agent_os, :autostart, original_autostart),
        else: Application.delete_env(:agent_os, :autostart)
    end)

    # Configure mock provider function to return a structured JSON response
    # matching the expected schema of ElicitorResponse.
    # We return input_tokens: 10, output_tokens: 20 -> price math is input: 10, output: 30 (from test config)
    # Total cost: 10 * 10 + 20 * 30 = 700 micro-dollars
    mock_response = %{
      "spec_draft" => %{
        "purpose" => "reply to recruiter emails",
        "capabilities" => ["gmail_read"],
        "boundaries" => %{"egress_domains" => ["gmail.googleapis.com"], "target_locations" => []},
        "spend_limits" => %{"dollar_cap" => 0.05, "token_limit" => 100_000},
        "confirmed" => false
      },
      "next_question" => "Should the agent send emails directly or just save drafts?",
      "scope_creep_detected" => false,
      "pushback_message" => ""
    }

    provider_fn = fn _model, _messages, _secret ->
      %{
        input_tokens: 10,
        output_tokens: 20,
        completion: Jason.encode!(mock_response)
      }
    end

    Application.put_env(:agent_os, :provider_fn, provider_fn)

    # Set low elicitor spend cap in configuration (e.g. 1000 micro-dollars)
    Application.put_env(:agent_os, :elicitor_spend_cap, 1000)

    # Start the session
    assert {:ok, pid} = ElicitationSession.start_link("reply to recruiter emails")

    # Verification 1: Spend ledger updated under "elicitor"
    ledger = AgentOS.StateStore.snapshot("spend_ledger")
    assert entry = Map.get(ledger, "elicitor")
    assert entry.spent == 700

    # Verification 2: Exceeding cap blocks next call
    # Submit a message which will trigger another LLM call
    # Since spent is 700, and next call costs 700, 700+700 = 1400 >= 1000 cap -> breach!
    assert {:error, {:exit_status, 1}} = ElicitationSession.submit_message(pid, "Gmail")

    # Verify the ledger updated to 1400 (one-call overshoot) and subsequent calls are blocked
    ledger2 = AgentOS.StateStore.snapshot("spend_ledger")
    assert ledger2["elicitor"].spent == 1400

    # Clean up provider_fn override
    Application.delete_env(:agent_os, :provider_fn)
  end
end
