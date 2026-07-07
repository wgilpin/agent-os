defmodule AgentOS.ActionTranscriptTest do
  use ExUnit.Case, async: false

  alias AgentOS.ActionTranscript
  alias AgentOS.ActionTranscript.Entry
  alias AgentOS.StateStore

  setup do
    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})

    tmp_file =
      Path.join(
        System.tmp_dir!(),
        "action_transcript_#{:erlang.unique_integer([:positive])}.db"
      )

    start_supervised!(
      {StateStore, name: "action_transcript", path: tmp_file, initial: %{}}
    )

    start_supervised!(AgentOS.InferenceBroker)

    token = "test_run_token_#{:erlang.unique_integer([:positive])}"
    %{run_token: token}
  end

  test "clear/1 then read/1 returns empty transcript", %{run_token: run_token} do
    # Read should return an empty struct
    assert %ActionTranscript{run_token: ^run_token, entries: []} = ActionTranscript.read(run_token)

    # Append something to make it non-empty
    entry =
      Entry.new(%{
        kind: :granted,
        connector: "discord_notify",
        method: "notify",
        arguments: %{"text" => "hello"},
        result: %{"success" => true},
        reason_code: nil
      })

    assert :ok = ActionTranscript.append(run_token, entry)

    # Verify it has entries
    assert %ActionTranscript{entries: [^entry]} = ActionTranscript.read(run_token)

    # Clear and read again
    assert :ok = ActionTranscript.clear(run_token)
    assert %ActionTranscript{entries: []} = ActionTranscript.read(run_token)
  end

  test "append/2 preserves order", %{run_token: run_token} do
    entry1 =
      Entry.new(%{
        kind: :granted,
        connector: "c1",
        method: "m1",
        arguments: %{},
        result: %{},
        reason_code: nil
      })

    entry2 =
      Entry.new(%{
        kind: :granted,
        connector: "c2",
        method: "m2",
        arguments: %{},
        result: %{},
        reason_code: nil
      })

    assert :ok = ActionTranscript.append(run_token, entry1)
    assert :ok = ActionTranscript.append(run_token, entry2)

    transcript = ActionTranscript.read(run_token)
    assert transcript.entries == [entry1, entry2]
  end

  test "rejected-entry validation requires reason_code" do
    assert_raise ArgumentError, "a :rejected entry MUST carry a reason_code", fn ->
      Entry.new(%{
        kind: :rejected,
        connector: "c1",
        method: nil,
        arguments: %{},
        result: nil,
        reason_code: nil
      })
    end

    # Should succeed when provided
    assert %Entry{kind: :rejected} =
             Entry.new(%{
               kind: :rejected,
               connector: "c1",
               method: nil,
               arguments: %{},
               result: nil,
               reason_code: :ungranted_connector
             })
  end

  test "record-mode granted-entry synthetic-result validation", %{run_token: run_token} do
    # Register the run token as record mode manually in InferenceBroker
    # Wait, we need InferenceBroker to be running for append to fetch the mode.
    # InferenceBroker is not running in this test.
    # Register the token
    AgentOS.InferenceBroker.register(
      run_token,
      "test_agent",
      %AgentOS.Manifest{
        purpose: "test",
        owner: "test",
        supervision: "test",
        grants: [],
        spend: %AgentOS.Manifest.Spend{cap: 1, window: :daily, on_breach: :kill}
      },
      :record,
      nil
    )

    entry =
      Entry.new(%{
        kind: :granted,
        connector: "c1",
        method: nil,
        arguments: %{},
        result: %{"wrong" => "result"},
        reason_code: nil
      })

    assert_raise ArgumentError, "result for a :record-mode :granted entry MUST be the synthetic success shape", fn ->
      ActionTranscript.append(run_token, entry)
    end

    valid_entry =
      Entry.new(%{
        kind: :granted,
        connector: "c1",
        method: nil,
        arguments: %{},
        result: %{"status" => "recorded"},
        reason_code: nil
      })

    assert :ok = ActionTranscript.append(run_token, valid_entry)
  end
end
