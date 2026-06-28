defmodule AgentOS.OutputCheckTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias AgentOS.OutputCheck

  @manifest %{
    "outputs" => ["append_digest"],
    "connectors" => ["record_signal"]
  }

  test "returns granted actions" do
    action = %{"type" => "append_digest", "payload" => %{"text" => "hello"}}
    assert {:ok, [^action]} = OutputCheck.validate([action], @manifest)
  end

  test "drops and logs ungranted actions" do
    action = %{"type" => "unauthorized_action", "payload" => %{}}

    log =
      capture_log(fn ->
        assert {:ok, []} = OutputCheck.validate([action], @manifest)
      end)

    assert log =~ "ungranted"
    assert log =~ "unauthorized_action"
  end

  test "drops and logs malformed actions (not a map)" do
    action = "not a map"

    log =
      capture_log(fn ->
        assert {:ok, []} = OutputCheck.validate([action], @manifest)
      end)

    assert log =~ "bad_shape"
  end

  test "drops and logs malformed actions (missing type)" do
    action = %{"payload" => %{}}

    log =
      capture_log(fn ->
        assert {:ok, []} = OutputCheck.validate([action], @manifest)
      end)

    assert log =~ "no_type"
  end

  test "returns empty list and logs when actions is not a list" do
    log =
      capture_log(fn ->
        assert {:ok, []} = OutputCheck.validate("not a list", @manifest)
      end)

    assert log =~ "not_a_list"
  end

  test "filters mixed granted and ungranted actions" do
    granted = %{"type" => "record_signal", "payload" => %{"signal" => "x"}}
    ungranted = %{"type" => "send_email", "payload" => %{}}

    log =
      capture_log(fn ->
        assert {:ok, [^granted]} = OutputCheck.validate([granted, ungranted], @manifest)
      end)

    assert log =~ "ungranted"
    assert log =~ "send_email"
  end
end
