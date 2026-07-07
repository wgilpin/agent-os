defmodule AgentOS.OutcomeRecordTest do
  use ExUnit.Case, async: true

  alias AgentOS.OutcomeRecord

  describe "parse/1 — accepts valid outcome records" do
    test "outcome + reason" do
      assert {:ok, %OutcomeRecord{outcome: "completed", reason: "handled via tool channel"}} =
               OutcomeRecord.parse(
                 ~s({"outcome": "completed", "reason": "handled via tool channel"})
               )
    end

    test "refused with reason" do
      assert {:ok, %OutcomeRecord{outcome: "refused", reason: "out of scope"}} =
               OutcomeRecord.parse(~s({"outcome": "refused", "reason": "out of scope"}))
    end

    test "empty reason string is allowed (key present)" do
      assert {:ok, %OutcomeRecord{outcome: "completed", reason: ""}} =
               OutcomeRecord.parse(~s({"outcome": "completed", "reason": ""}))
    end

    test "tolerates surrounding whitespace / trailing newline" do
      assert {:ok, %OutcomeRecord{outcome: "completed"}} =
               OutcomeRecord.parse(~s({"outcome": "completed", "reason": "x"}\n))
    end
  end

  describe "parse/1 — rejects malformed input" do
    test "legacy actions protocol" do
      assert {:error, :malformed} = OutcomeRecord.parse(~s({"actions": []}))
    end

    test "missing reason" do
      assert {:error, :malformed} = OutcomeRecord.parse(~s({"outcome": "completed"}))
    end

    test "missing outcome" do
      assert {:error, :malformed} = OutcomeRecord.parse(~s({"reason": "x"}))
    end

    test "non-string outcome" do
      assert {:error, :malformed} = OutcomeRecord.parse(~s({"outcome": 1, "reason": "x"}))
    end

    test "non-JSON" do
      assert {:error, :malformed} = OutcomeRecord.parse("not json")
    end

    test "empty stdout" do
      assert {:error, :malformed} = OutcomeRecord.parse("")
    end

    test "non-binary input" do
      assert {:error, :malformed} = OutcomeRecord.parse(nil)
    end
  end
end
