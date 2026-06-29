defmodule AgentOS.GateTest do
  use ExUnit.Case, async: true

  alias AgentOS.Gate
  alias AgentOS.ProposedAction
  alias AgentOS.Manifest
  alias AgentOS.Manifest.Grant
  alias AgentOS.Manifest.Spend

  # Define mock inputs
  defp mock_manifest(grants, spend_cap \\ 500_000) do
    %Manifest{
      purpose: "Test purpose",
      owner: "human",
      supervision: "restart-once-and-alert",
      grants: grants,
      spend: %Spend{cap: spend_cap, window: :daily, on_breach: :kill},
      mounts: [],
      triggers: []
    }
  end

  defp mock_registry do
    %{
      "kv_append" => %{
        name: "kv_append",
        mutating?: true,
        requires_approval?: false,
        credential: nil,
        cost: 0
      },
      "external_send" => %{
        name: "external_send",
        mutating?: true,
        requires_approval?: true,
        credential: :outbound_token,
        cost: 2000
      }
    }
  end

  test "approves in-scope action within spend cap" do
    action = %ProposedAction{type: "kv_append", recipient: nil, method: "append", payload: %{}}
    grant = %Grant{connector: "kv_append", recipients: nil, methods: ["append"]}
    manifest = mock_manifest([grant])

    assert {:approve, ^grant} = Gate.evaluate(action, manifest, mock_registry(), %{spent: 0})
  end

  test "rejects action type not in manifest grants (unknown_action)" do
    action = %ProposedAction{type: "external_send", recipient: nil, method: nil, payload: %{}}
    grant = %Grant{connector: "kv_append", recipients: nil, methods: ["append"]}
    manifest = mock_manifest([grant])

    assert {:reject, :unknown_action} =
             Gate.evaluate(action, manifest, mock_registry(), %{spent: 0})
  end

  test "rejects action when recipient is out of scope" do
    action = %ProposedAction{
      type: "external_send",
      recipient: "malicious-inbox",
      method: "send",
      payload: %{}
    }

    grant = %Grant{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}
    manifest = mock_manifest([grant])

    assert {:reject, :recipient_out_of_scope} =
             Gate.evaluate(action, manifest, mock_registry(), %{spent: 0})
  end

  test "rejects action when method is out of scope" do
    action = %ProposedAction{type: "kv_append", recipient: nil, method: "delete", payload: %{}}
    grant = %Grant{connector: "kv_append", recipients: nil, methods: ["append"]}
    manifest = mock_manifest([grant])

    assert {:reject, :method_out_of_scope} =
             Gate.evaluate(action, manifest, mock_registry(), %{spent: 0})
  end

  test "returns breach when action cost exceeds spend cap" do
    # cost of external_send is 2000. current spent: 5000, cap: 5000 => 5000 + 2000 > 5000 (breach)
    action = %ProposedAction{
      type: "external_send",
      recipient: "owner-inbox",
      method: "send",
      payload: %{}
    }

    grant = %Grant{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}
    manifest = mock_manifest([grant], 5000)

    assert {:breach, :spend} = Gate.evaluate(action, manifest, mock_registry(), %{spent: 5000})
  end

  test "allows spent + cost exactly equal to spend cap" do
    # cost of external_send is 2000. current spent: 3000, cap: 5000 => 3000 + 2000 == 5000 (allowed)
    action = %ProposedAction{
      type: "external_send",
      recipient: "owner-inbox",
      method: "send",
      payload: %{}
    }

    grant = %Grant{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}
    manifest = mock_manifest([grant], 5000)

    assert {:needs_approval, ^grant} =
             Gate.evaluate(action, manifest, mock_registry(), %{spent: 3000})
  end

  test "parks action requiring approval" do
    action = %ProposedAction{
      type: "external_send",
      recipient: "owner-inbox",
      method: "send",
      payload: %{}
    }

    grant = %Grant{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}
    manifest = mock_manifest([grant])

    assert {:needs_approval, ^grant} =
             Gate.evaluate(action, manifest, mock_registry(), %{spent: 0})
  end

  test "partition_batch correctly splits proposed actions" do
    grants = [
      %Grant{connector: "kv_append", recipients: nil, methods: ["append"]},
      %Grant{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}
    ]

    # cap = 3000
    manifest = mock_manifest(grants, 3000)

    raw_actions = [
      # 1. Approved (cost 0, spent cumulative = 0)
      %{"type" => "kv_append", "method" => "append"},
      # 2. Rejected - bad shape
      %{"foo" => "bar"},
      # 3. Rejected - unknown action
      %{"type" => "unknown_connector"},
      # 4. Needs approval (cost 2000, spent cumulative = 2000)
      %{"type" => "external_send", "recipient" => "owner-inbox", "method" => "send"},
      # 5. Breached (cost 2000, spent cumulative = 4000 > 3000 cap)
      %{"type" => "external_send", "recipient" => "owner-inbox", "method" => "send"}
    ]

    # Partition the batch
    {approved, parked, rejected, breached} =
      Gate.partition_batch(raw_actions, manifest, mock_registry(), %{spent: 0})

    # Assert approved
    assert length(approved) == 1

    assert [%{action: %ProposedAction{type: "kv_append"}, grant: %Grant{connector: "kv_append"}}] =
             approved

    # Assert parked
    assert length(parked) == 1

    assert [
             %{
               action: %ProposedAction{type: "external_send"},
               grant: %Grant{connector: "external_send"}
             }
           ] = parked

    # Assert rejected
    assert length(rejected) == 2

    assert [{%{"foo" => "bar"}, :bad_shape}, {%{"type" => "unknown_connector"}, :unknown_action}] =
             rejected

    # Assert breached
    assert length(breached) == 1
    assert [%ProposedAction{type: "external_send"}] = breached
  end
end
