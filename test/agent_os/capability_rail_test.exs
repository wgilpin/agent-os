defmodule AgentOS.CapabilityRailTest do
  use ExUnit.Case, async: false

  alias AgentOS.CapabilityRail
  alias AgentOS.Manifest
  alias AgentOS.Manifest.Spend
  alias AgentOS.ActionTranscript

  setup do
    tmp_transcript =
      Path.join(
        System.tmp_dir!(),
        "action_transcript_rail_test_#{System.unique_integer([:positive])}.db"
      )

    tmp_spend =
      Path.join(
        System.tmp_dir!(),
        "spend_ledger_rail_test_#{System.unique_integer([:positive])}.db"
      )

    on_exit(fn ->
      File.rm(tmp_transcript)
      File.rm(tmp_spend)
    end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})

    start_supervised!(
      {AgentOS.StateStore, name: "action_transcript", path: tmp_transcript, initial: %{}}
    )

    start_supervised!({AgentOS.StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})

    start_supervised!(AgentOS.CredentialProxy)
    start_supervised!(AgentOS.InferenceBroker)

    run_token = "rail_run_token"
    agent_name = "rail_agent"

    manifest = %Manifest{
      purpose: "Rail test",
      owner: "human",
      supervision: "none",
      grants: [],
      spend: %Spend{cap: 2000, window: :daily, on_breach: :kill},
      mounts: [],
      triggers: []
    }

    AgentOS.InferenceBroker.register(run_token, agent_name, manifest)

    {:ok, run_token: run_token, agent_name: agent_name, manifest: manifest}
  end

  test "blocks ungranted tool and appends rejected entry", context do
    tool_calls = [
      %{
        "id" => "call_1",
        "function" => %{
          "name" => "web_search",
          "arguments" => "{\"query\": \"test\"}"
        }
      }
    ]

    assert {:ok, messages, cost} =
             CapabilityRail.evaluate_tool_calls(
               tool_calls,
               context.agent_name,
               context.manifest,
               context.run_token
             )

    assert cost == 0
    assert length(messages) == 1
    assert hd(messages)["content"] =~ "unauthorized tool 'web_search'"

    transcript = ActionTranscript.read(context.run_token)
    assert length(transcript.entries) == 1
    entry = hd(transcript.entries)
    assert entry.kind == :rejected
    assert entry.connector == "web_search"
    assert entry.reason_code == :ungranted_connector
  end

  test "blocks ungranted method for granted tool and appends rejected entry", context do
    # Grant web_search but only for "search" method
    manifest = %{
      context.manifest
      | grants: [%Manifest.Grant{connector: "web_search", methods: ["search"], recipients: nil}]
    }

    tool_calls = [
      %{
        "id" => "call_method",
        "function" => %{
          "name" => "web_search",
          "arguments" => "{\"method\": \"delete\"}"
        }
      }
    ]

    assert {:ok, messages, cost} =
             CapabilityRail.evaluate_tool_calls(
               tool_calls,
               context.agent_name,
               manifest,
               context.run_token
             )

    assert cost == 0
    assert length(messages) == 1
    assert hd(messages)["content"] =~ "unauthorized method 'delete' for tool 'web_search'"

    transcript = ActionTranscript.read(context.run_token)
    assert length(transcript.entries) == 1
    entry = hd(transcript.entries)
    assert entry.kind == :rejected
    assert entry.connector == "web_search"
    assert entry.method == "delete"
    assert entry.reason_code == :ungranted_method
  end

  test "blocks unknown tool and appends rejected entry", context do
    # Grant an unknown connector
    manifest = %{
      context.manifest
      | grants: [
          %Manifest.Grant{connector: "not_a_real_connector", methods: nil, recipients: nil}
        ]
    }

    tool_calls = [
      %{
        "id" => "call_2",
        "function" => %{
          "name" => "not_a_real_connector",
          "arguments" => "{}"
        }
      }
    ]

    assert {:ok, messages, cost} =
             CapabilityRail.evaluate_tool_calls(
               tool_calls,
               context.agent_name,
               manifest,
               context.run_token
             )

    assert cost == 0
    assert length(messages) == 1
    assert hd(messages)["content"] =~ "unknown connector"

    transcript = ActionTranscript.read(context.run_token)
    assert length(transcript.entries) == 1
    entry = hd(transcript.entries)
    assert entry.kind == :rejected
    assert entry.reason_code == :unknown_connector
  end

  test "executes granted tool and appends granted entry", context do
    # Requires web_search connector to be available in the registry, which it is for tests.
    manifest = %{
      context.manifest
      | grants: [%Manifest.Grant{connector: "web_search", methods: ["search"], recipients: nil}]
    }

    Application.put_env(:agent_os, :web_search_mock_fn, fn _q -> {:ok, "mock results"} end)
    on_exit(fn -> Application.delete_env(:agent_os, :web_search_mock_fn) end)

    tool_calls = [
      %{
        "id" => "call_3",
        "function" => %{
          "name" => "web_search",
          "arguments" => "{\"query\": \"mock\"}"
        }
      }
    ]

    assert {:ok, messages, cost} =
             CapabilityRail.evaluate_tool_calls(
               tool_calls,
               context.agent_name,
               manifest,
               context.run_token
             )

    # Configured cost for web_search
    assert cost == 1000
    assert length(messages) == 1
    assert hd(messages)["content"] == "mock results"

    transcript = ActionTranscript.read(context.run_token)
    assert length(transcript.entries) == 1
    entry = hd(transcript.entries)
    assert entry.kind == :granted
    assert entry.connector == "web_search"
    assert entry.result == "mock results"
  end

  test "parks an approval-required connector instead of executing it", context do
    # external_send carries requires_runtime_approval?: true. In live mode the rail
    # MUST NOT execute it; it records a :parked entry and queues it for human approval.
    start_supervised!(
      {AgentOS.StateStore,
       name: "pending_approvals",
       path:
         Path.join(
           System.tmp_dir!(),
           "pending_approvals_rail_#{System.unique_integer([:positive])}.db"
         ),
       initial: %{approvals: %{}}}
    )

    manifest = %{
      context.manifest
      | spend: %Spend{cap: 5000, window: :daily, on_breach: :kill},
        grants: [
          %Manifest.Grant{
            connector: "external_send",
            methods: ["send"],
            recipients: ["owner-inbox"]
          }
        ]
    }

    tool_calls = [
      %{
        "id" => "call_send",
        "function" => %{
          "name" => "external_send",
          "arguments" => "{\"message\": \"hello\"}"
        }
      }
    ]

    assert {:ok, messages, cost} =
             CapabilityRail.evaluate_tool_calls(
               tool_calls,
               context.agent_name,
               manifest,
               context.run_token
             )

    # Not executed => not charged, and the model is told it is pending approval.
    assert cost == 0
    assert hd(messages)["content"] =~ "pending approval"

    # Recorded as parked, never as granted.
    transcript = ActionTranscript.read(context.run_token)
    assert length(transcript.entries) == 1
    entry = hd(transcript.entries)
    assert entry.kind == :parked
    assert entry.connector == "external_send"
    assert entry.result == nil

    # Queued for human approval in the exact shape the resume path (TriggerGateway) consumes.
    pending = AgentOS.StateStore.snapshot("pending_approvals")
    approvals = Map.get(pending, :approvals, %{})
    assert map_size(approvals) == 1
    [%{action: action, grant: grant}] = Map.values(approvals)
    assert action.type == "external_send"
    assert action.method == "send"
    assert grant.connector == "external_send"
  end
end
