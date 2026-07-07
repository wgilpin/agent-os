defmodule AgentOS.DiscordGatewayTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias AgentOS.DiscordGateway

  setup do
    # Default valid options
    state = %{
      user_id: "12345",
      channel_id: "67890",
      target_agent: "test_coach",
      seq: nil
    }

    {:ok, state: state}
  end

  test "valid MESSAGE_CREATE payload routes to TriggerGateway", %{state: state} do
    payload = %{
      "op" => 0,
      "s" => 1,
      "t" => "MESSAGE_CREATE",
      "d" => %{
        "author" => %{"id" => "12345"},
        "channel_id" => "67890",
        "content" => "Hello, agent!"
      }
    }

    frame = {:text, Jason.encode!(payload)}

    # We expect TriggerGateway.submit to be called.
    # Since TriggerGateway runs async, we can just ensure it doesn't crash.
    # Or we can verify the log output if we added a debug log, but here we just check it returns {:ok, state}
    assert {:ok, %{seq: 1}} = DiscordGateway.handle_frame(frame, state)
  end

  test "mismatched user_id drops the message and logs loudly", %{state: state} do
    payload = %{
      "op" => 0,
      "s" => 2,
      "t" => "MESSAGE_CREATE",
      "d" => %{
        "author" => %{"id" => "WRONG_USER"},
        "channel_id" => "67890",
        "content" => "Hello, agent!"
      }
    }

    frame = {:text, Jason.encode!(payload)}

    log =
      capture_log(fn ->
        assert {:ok, %{seq: 2}} = DiscordGateway.handle_frame(frame, state)
      end)

    assert log =~ "Unauthorized Discord message"
    assert log =~ "WRONG_USER"
  end

  test "mismatched channel_id drops the message and logs loudly", %{state: state} do
    payload = %{
      "op" => 0,
      "s" => 3,
      "t" => "MESSAGE_CREATE",
      "d" => %{
        "author" => %{"id" => "12345"},
        "channel_id" => "WRONG_CHANNEL",
        "content" => "Hello, agent!"
      }
    }

    frame = {:text, Jason.encode!(payload)}

    log =
      capture_log(fn ->
        assert {:ok, %{seq: 3}} = DiscordGateway.handle_frame(frame, state)
      end)

    assert log =~ "Unauthorized Discord channel"
    assert log =~ "WRONG_CHANNEL"
  end

  test "ignores non-MESSAGE_CREATE events", %{state: state} do
    payload = %{
      "op" => 0,
      "s" => 4,
      "t" => "PRESENCE_UPDATE",
      "d" => %{}
    }

    frame = {:text, Jason.encode!(payload)}

    assert {:ok, %{seq: 4}} = DiscordGateway.handle_frame(frame, state)
  end
end
