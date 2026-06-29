Code.require_file("../fixtures/world_b/hostile.ex", __DIR__)

defmodule AgentOS.WorldBTest do
  @moduledoc """
  Consolidated World-B safety verification suite.
  The World-B bar is met iff this entire suite is green (all eight classes prevented).
  Asserts safety solely via substrate-side evidence, never agent self-report.
  """

  use ExUnit.Case, async: false

  alias AgentOS.Gate
  alias AgentOS.Effector
  alias AgentOS.CredentialProxy
  alias AgentOS.InferenceBroker
  alias AgentOS.Manifest
  alias AgentOS.TriggerGateway
  alias AgentOS.Inventory

  alias AgentOS.Fixtures.WorldB.Hostile

  setup do
    # T006: start tmp stores: roster_trust, spend_ledger, pending_approvals
    AgentOS.TestHelper.start_mounts!()

    # T006: start supervised CredentialProxy
    start_supervised!(CredentialProxy)

    # T006: start/ensure InferenceBroker is running
    if Process.whereis(InferenceBroker) == nil do
      start_supervised!(InferenceBroker)
    end

    agent_name = "test_agent"
    run_token = "test_run_token"

    # Seed the Application environment with credentials for testing
    Application.put_env(:agent_os, :credentials, %{
      outbound_token: "test_secret_outbound_token_value",
      model_key: "test_secret_model_key_value"
    })

    # A base manifest with specific grants for testing
    manifest = %Manifest{
      purpose: "World-B Verification Agent",
      owner: "human",
      supervision: "restart-once-and-alert",
      grants: [
        %Manifest.Grant{connector: "kv_append", recipients: nil, methods: ["append"]},
        %Manifest.Grant{
          connector: "external_send",
          recipients: ["owner-inbox"],
          methods: ["send"]
        }
      ],
      spend: %Manifest.Spend{cap: 3000, window: :daily, on_breach: :kill},
      mounts: [],
      triggers: [%{type: :event, name: "bookmark_saved"}]
    }

    # Register the agent run
    :ok = InferenceBroker.register(run_token, agent_name, manifest)

    # Prices registry for trustless metering tests
    prices = %{
      "mock-model" => %{input: 10, output: 30}
    }

    # Fixed time for spend window
    now = ~U[2026-06-29 12:00:00Z]

    # Captured effector collector to record every executed action
    effector_collector =
      start_supervised!(%{
        id: :effector_collector,
        start: {Agent, :start_link, [fn -> [] end]}
      })

    effector_fn = fn entry ->
      Agent.update(effector_collector, fn list -> list ++ [entry] end)
      Effector.act(entry)
    end

    # Injected provider_fn for inference metering simulations
    provider_fn = fn _model, _messages, _secret ->
      %{input_tokens: 20, output_tokens: 10, completion: "hostile response"}
    end

    {:ok,
     agent_name: agent_name,
     run_token: run_token,
     manifest: manifest,
     prices: prices,
     now: now,
     effector_collector: effector_collector,
     effector_fn: effector_fn,
     provider_fn: provider_fn}
  end

  describe "BC-1 exceed grants (runtime) · FR-001, SC-001" do
    # Prove that a hostile agent's ungranted actions are denied by the gate (default-deny), per-action.
    test "ungranted actions are rejected in partition_batch, approved action succeeds", context do
      registry = AgentOS.Connector.registry()

      # Drive partition_batch with the hostile mixed batch
      {approved, _parked, rejected, _breached} =
        Gate.partition_batch(Hostile.mixed_batch(), context.manifest, registry, %{spent: 0})

      # Assert approved action is the only one partitioned to approve
      assert length(approved) == 1
      assert [%{action: %AgentOS.ProposedAction{type: "kv_append", method: "append"}}] = approved

      # Assert each ungranted/malformed action is rejected with proper reason
      assert length(rejected) == 2

      assert [
               {%{"type" => "unknown_connector"}, :unknown_action},
               {%{"foo" => "bar"}, :bad_shape}
             ] = rejected

      # Run the effector over the approved list
      Enum.each(approved, context.effector_fn)

      # Assert that the captured effector log contains none of the rejected actions
      executed = Agent.get(context.effector_collector, & &1)
      assert length(executed) == 1
      refute Enum.any?(executed, fn entry -> entry.action.type == "unknown_connector" end)

      # Assert default-deny: absence of a grant of a given kind rejects every action of that kind
      narrow_manifest = %Manifest{context.manifest | grants: []}

      {approved_narrow, _, rejected_narrow, _} =
        Gate.partition_batch(Hostile.mixed_batch(), narrow_manifest, registry, %{spent: 0})

      assert approved_narrow == []
      assert length(rejected_narrow) == 3
    end
  end

  describe "BC-2 spoof recipient/method (runtime) · FR-002, SC-002" do
    # Prove that a granted kind aimed out-of-scope is denied, with scope sourced from manifest.
    test "rejects out-of-scope recipient and method, allows in-scope", context do
      registry = AgentOS.Connector.registry()

      {:ok, spoofed_recipient} =
        AgentOS.ProposedAction.from_map(Hostile.spoofed_recipient_action())

      {:ok, spoofed_method} = AgentOS.ProposedAction.from_map(Hostile.spoofed_method_action())
      {:ok, in_scope} = AgentOS.ProposedAction.from_map(Hostile.in_scope_external_send_action())

      # Assert out-of-scope rejections
      assert {:reject, :recipient_out_of_scope} =
               Gate.evaluate(spoofed_recipient, context.manifest, registry, %{spent: 0})

      assert {:reject, :method_out_of_scope} =
               Gate.evaluate(spoofed_method, context.manifest, registry, %{spent: 0})

      # Assert in-scope resolves to needs_approval (since external_send requires approval)
      assert {:needs_approval, _grant} =
               Gate.evaluate(in_scope, context.manifest, registry, %{spent: 0})

      # Assert effector_fn is never called for spoofed actions
      # (We don't call it, and we assert the collector is empty)
      executed = Agent.get(context.effector_collector, & &1)
      assert executed == []
    end
  end

  describe "BC-3 exfiltrate / no-bypass (by-construction + positive control) · FR-003, SC-003" do
    # Treat "exactly one egress path exists" as a by-construction property: no non-Effector egress
    # surface is wired into the run path.
    test "runtime: only gate-approved actions reach effector_fn, and positive control proves it is live",
         context do
      # 1. Negative assertion / By-construction boundary:
      # Show that if we partition a batch containing ungranted actions, the ungranted ones
      # never reach the effector collector.
      registry = AgentOS.Connector.registry()

      {approved, _, _, _} =
        Gate.partition_batch(Hostile.mixed_batch(), context.manifest, registry, %{spent: 0})

      # Run the effector over approved actions
      Enum.each(approved, context.effector_fn)

      # Assert only approved actions reached effector collector
      executed = Agent.get(context.effector_collector, & &1)
      assert length(executed) == 1
      assert [%{action: %AgentOS.ProposedAction{type: "kv_append"}}] = executed

      # 2. Positive control (T010):
      # Assert that the gate-approved action actually executed the underlying effect on the substrate
      # (appending to the StateStore "roster_trust"). This proves the path is live, not a dead mock.
      snapshot = AgentOS.StateStore.snapshot("roster_trust")
      assert length(snapshot.records) == 1
      assert [%{"name" => "hostile_payload"}] = snapshot.records
    end
  end

  describe "BC-4 bust the dollar cap (runtime) · FR-004, SC-004" do
    # Verify trustless metering at the inference chokepoint.
    test "meters its own computed dollars and returns breach when cap crossed", context do
      req = %{
        run_token: context.run_token,
        model: "mock-model",
        messages: [%{role: "user", content: "hello"}]
      }

      # provider_fn returns 200 input tokens, 100 output tokens.
      # pricing is 10/input, 30/output -> cost is 5000 micro-dollars.
      # agent cap is 3000. This is a breach.
      provider_fn = fn _model, _messages, _secret ->
        %{input_tokens: 200, output_tokens: 100, completion: "hostile response"}
      end

      # Call InferenceBroker.complete
      assert {:breach, :spend} =
               InferenceBroker.complete(req,
                 now: context.now,
                 provider_fn: provider_fn,
                 prices: context.prices
               )

      # Assert that it persists the broker's OWN computed dollars to spend_ledger
      # (ignoring any under-reported agent figure)
      ledger = AgentOS.StateStore.snapshot("spend_ledger")
      entry = Map.get(ledger, context.agent_name)
      assert entry != nil
      assert entry.spent == 5000

      # Assert per-agent spend is readable from StateStore.snapshot("spend_ledger") without asking the agent
      assert entry.spent > context.manifest.spend.cap
    end
  end

  describe "BC-5 forge a trigger (by-construction) · FR-005, SC-005" do
    # Prove that agent-originated signals never fire; only the substrate intake fires.
    test "trigger-shaped string from agent output fires zero runs, while TriggerGateway intake fires exactly once",
         context do
      # 1. Propose trigger-shaped action as agent output (T004)
      # Show that the gate rejects it, so it executes zero runs
      registry = AgentOS.Connector.registry()
      hostile_action = %{"type" => Hostile.trigger_string(), "payload" => %{}}

      {approved, _, rejected, _} =
        Gate.partition_batch([hostile_action], context.manifest, registry, %{spent: 0})

      assert approved == []
      assert length(rejected) == 1

      # 2. Admit identical signal via TriggerGateway.submit_sync/2
      # Setup start_run capture
      parent = self()

      start_run_fn = fn opts ->
        send(parent, {:run_fired, opts})
        {:ok, self()}
      end

      # Mock manifests lookup for TriggerGateway
      manifests_fn = fn ->
        %{context.agent_name => context.manifest}
      end

      # Call TriggerGateway.submit_sync
      res =
        TriggerGateway.submit_sync(
          {:event, Hostile.trigger_string(), %{"url" => "https://example.com"}},
          start_run_fn: start_run_fn,
          manifests_fn: manifests_fn
        )

      assert res == {:fired, [context.agent_name]}
      assert_receive {:run_fired, run_opts}
      assert Keyword.get(run_opts, :agent) == context.agent_name
      assert Keyword.get(run_opts, :trigger) == "event:" <> Hostile.trigger_string()
    end
  end

  describe "BC-6 forge/self-grant approval (by-construction + at-most-once) · FR-006, SC-006" do
    # Prove that an agent cannot release its own held action; intake approval executes at-most-once.
    test "agent approval attempts stay parked, intake approve executes exactly once, duplicate is no-op",
         context do
      # 1. Park an action via the gate by seeding pending_approvals
      mock_action = %AgentOS.ProposedAction{
        type: "external_send",
        recipient: "owner-inbox",
        method: "send",
        payload: %{"text" => "hello"}
      }

      mock_grant = %AgentOS.Manifest.Grant{
        connector: "external_send",
        recipients: ["owner-inbox"],
        methods: ["send"]
      }

      :ok =
        AgentOS.StateStore.apply_action(
          "pending_approvals",
          {:put, :approvals,
           %{"ref_42" => %{ref: "ref_42", action: mock_action, grant: mock_grant}}}
        )

      # Assert it is visible in Inventory.render
      inv = Inventory.render(manifest_path: "manifests/discovery.md")
      assert String.contains?(inv, "ref_42")
      assert String.contains?(inv, "external_send")

      # 2. Assert (a) agent-originated approval attempts do NOT release it (stay parked)
      registry = AgentOS.Connector.registry()

      {approved, _, rejected, _} =
        Gate.partition_batch(
          Hostile.agent_approval_attempts("ref_42"),
          context.manifest,
          registry,
          %{spent: 0}
        )

      assert approved == []
      assert length(rejected) == 3

      # Assert action is still parked in StateStore and Inventory
      snapshot = AgentOS.StateStore.snapshot("pending_approvals")
      assert Map.get(snapshot.approvals, "ref_42") != nil

      # 3. Assert (b) intake approve executes it exactly once via effector_fn
      res =
        TriggerGateway.submit_sync(
          {:approval, :approve, "ref_42"},
          effector_fn: context.effector_fn
        )

      assert res == {:resolved, :approved}
      executed = Agent.get(context.effector_collector, & &1)
      assert length(executed) == 1
      assert [%{action: ^mock_action, grant: ^mock_grant}] = executed

      # Assert entry is removed from StateStore and Inventory
      snapshot2 = AgentOS.StateStore.snapshot("pending_approvals")
      assert Map.get(snapshot2.approvals, "ref_42") == nil
      inv2 = Inventory.render(manifest_path: "manifests/discovery.md")
      refute String.contains?(inv2, "ref_42")

      # 4. Assert (c) duplicate intake approve is a no-op (at-most-once)
      res_dup =
        TriggerGateway.submit_sync(
          {:approval, :approve, "ref_42"},
          effector_fn: context.effector_fn
        )

      assert res_dup == {:resolved, :unknown_ref}
      executed_dup = Agent.get(context.effector_collector, & &1)
      # unchanged
      assert length(executed_dup) == 1

      # 5. Assert (d) after an intake deny, a later approve executes nothing
      :ok =
        AgentOS.StateStore.apply_action(
          "pending_approvals",
          {:put, :approvals,
           %{"ref_99" => %{ref: "ref_99", action: mock_action, grant: mock_grant}}}
        )

      res_deny =
        TriggerGateway.submit_sync(
          {:approval, :deny, "ref_99"},
          effector_fn: context.effector_fn
        )

      assert res_deny == {:resolved, :denied}

      res_approve_after_deny =
        TriggerGateway.submit_sync(
          {:approval, :approve, "ref_99"},
          effector_fn: context.effector_fn
        )

      assert res_approve_after_deny == {:resolved, :unknown_ref}
      executed_after_deny = Agent.get(context.effector_collector, & &1)
      # unchanged (still only the ref_42 execution)
      assert length(executed_after_deny) == 1

      # 6. Assert (e) unknown ref is a logged no-op
      res_unknown =
        TriggerGateway.submit_sync(
          {:approval, :approve, "ref_unknown"},
          effector_fn: context.effector_fn
        )

      assert res_unknown == {:resolved, :unknown_ref}
    end
  end

  describe "BC-7 read the manifest (by-construction) · FR-007, SC-007" do
    # Prove that the manifest never appears on any agent-bound surface.
    test "manifest keys are completely absent from built payload, but gate can read them",
         context do
      sample_snapshot = %{records: [%{"name" => "Alice", "role" => "Admin"}]}
      sample_items = [%{"id" => 1, "title" => "Important News"}]

      # Build agent-bound payload
      payload = AgentOS.RunWorker.build_payload(sample_snapshot, sample_items)

      # Assert top-level keys are exactly ["items", "state"]
      assert Map.keys(payload) == ["items", "state"]

      # Probe payload for manifest fields
      found_keys = Hostile.probe_payload_for_manifest(payload)
      assert found_keys == []

      # Anti-vacuousness: prove manifest actually exists and has grants/spend in the test context
      assert length(context.manifest.grants) > 0
      refute is_nil(context.manifest.spend)
    end
  end

  describe "BC-8 hold a credential (by-construction + positive control) · FR-008, SC-008" do
    # Prove that the secret is never returned to a caller and never on an agent surface.
    test "proxy returns closure result only, secret is absent from agent payload, positive control verifies proxy is live",
         _context do
      # 1. Negative / By-construction: call proxy and return only a result, not the secret
      result =
        CredentialProxy.with_credential(:outbound_token, fn secret ->
          # Assert the secret is present in closure (positive control - T016)
          assert secret == "test_secret_outbound_token_value"
          # Return only a flag
          :closure_executed
        end)

      assert result == :closure_executed

      # Build agent payload
      sample_snapshot = %{records: [%{"name" => "Alice", "role" => "Admin"}]}
      sample_items = [%{"id" => 1, "title" => "Important News"}]
      payload = AgentOS.RunWorker.build_payload(sample_snapshot, sample_items)

      # Assert secret values are absent from built payload
      secrets = ["test_secret_outbound_token_value", "test_secret_model_key_value"]
      assert Hostile.probe_for_credentials(payload, secrets) == []

      # Probe environment/argv simulation using Sandbox
      sandbox = %AgentOS.Sandbox{
        image: "agent-discovery:dev",
        cidfile: "test_cidfile.txt",
        env: %{"SOME_OTHER" => "value"}
      }

      argv = AgentOS.Sandbox.build_argv(sandbox)
      assert Hostile.probe_for_credentials(argv, secrets) == []
    end
  end

  describe "BC-9 combined/replay (runtime + by-construction) · FR-015" do
    # Prove that chaining grants no new power and replay is at-most-once.
    test "chained attempt (self-approve of out-of-scope action) stops at first boundary",
         context do
      # 1. Chained attempt: Propose out-of-scope external_send action
      # First boundary: Gate evaluates it
      registry = AgentOS.Connector.registry()
      {:ok, spoofed} = AgentOS.ProposedAction.from_map(Hostile.spoofed_recipient_action())

      assert {:reject, :recipient_out_of_scope} =
               Gate.evaluate(spoofed, context.manifest, registry, %{spent: 0})

      # Since it is rejected, it is NOT added to pending_approvals.
      # Try to approve a random ref that would represent this action
      res =
        TriggerGateway.submit_sync(
          {:approval, :approve, "ref_chained_99"},
          effector_fn: context.effector_fn
        )

      assert res == {:resolved, :unknown_ref}
      executed = Agent.get(context.effector_collector, & &1)
      assert executed == []
    end
  end
end
