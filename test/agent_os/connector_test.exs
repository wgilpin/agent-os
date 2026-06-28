defmodule AgentOS.ConnectorTest do
  use ExUnit.Case, async: true

  alias AgentOS.Connector

  test "exposes registered connectors with correct metadata" do
    assert {:ok, kv} = Connector.get("kv_append")
    assert kv.name == "kv_append"
    assert kv.mutating? == true
    assert kv.requires_approval? == false
    assert kv.credential == nil
    assert kv.cost == 1

    assert {:ok, ext} = Connector.get("external_send")
    assert ext.name == "external_send"
    assert ext.mutating? == true
    assert ext.requires_approval? == true
    assert ext.credential == :outbound_token
    assert ext.cost == 2
  end

  test "returns error for unknown connector" do
    assert {:error, :unknown_connector} = Connector.get("unknown_connector")
  end

  test "returns all registered names" do
    names = Connector.registered_names()
    assert "kv_append" in names
    assert "external_send" in names
  end
end
