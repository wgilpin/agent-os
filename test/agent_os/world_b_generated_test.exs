Code.require_file("../fixtures/world_b/hostile.ex", __DIR__)
Code.require_file("../fixtures/generation/generation.ex", __DIR__)

defmodule AgentOS.WorldBGeneratedTest do
  @moduledoc """
  Consolidated World-B safety verification suite for machine-written manifest & code.
  Asserts safety solely via substrate-side evidence, never agent self-report.
  """

  use ExUnit.Case, async: false

  alias AgentOS.Gate
  alias AgentOS.Effector
  alias AgentOS.CredentialProxy
  alias AgentOS.InferenceBroker
  alias AgentOS.Manifest
  alias AgentOS.TriggerGateway

  alias AgentOS.Fixtures.WorldB.Hostile
  alias AgentOS.Fixtures.Generation

  @model "mock-model"
  @prices %{"mock-model" => %{input: 10_000_000, output: 30_000_000}}
  @now ~U[2026-06-29 12:00:00Z]

  setup do
    # T006: start tmp stores
    AgentOS.TestHelper.start_mounts!()

    # Start supervised CredentialProxy & InferenceBroker
    start_supervised!(CredentialProxy)

    if Process.whereis(InferenceBroker) == nil do
      start_supervised!(InferenceBroker)
    end

    agent_name = "test_agent"
    run_token = "test_run_token"

    Application.put_env(:agent_os, :credentials, %{
      outbound_token: "test_secret_outbound_token_value",
      model_key: "test_secret_model_key_value"
    })

    # T011: obtain manifest from projection of recruiter_confirmed_spec/0
    spec = Generation.recruiter_confirmed_spec()
    {:ok, manifest} = AgentOS.Manifest.Projection.project(spec)

    # Setup directories
    dirs = Generation.tmp_dirs()

    on_exit(fn ->
      File.rm_rf!(dirs.spec_dir)
      File.rm_rf!(dirs.manifest_dir)
    end)

    # Synthesise the body via Stage4.generate/3 behind a stubbed provider_fn
    provider_fn = fn _model, _messages, _secret ->
      body = Generation.stub_agent_body()
      files = Enum.map(body, fn {path, content} -> %{"path" => path, "content" => content} end)

      %{
        input_tokens: 10,
        output_tokens: 10,
        completion: Jason.encode!(%{"files" => files})
      }
    end

    opts = [
      run_token: run_token,
      model: @model,
      prices: @prices,
      now: @now,
      spec_dir: dirs.spec_dir,
      provider_fn: provider_fn
    ]

    :ok = InferenceBroker.register(run_token, agent_name, manifest)

    # Synthesise body (machine-written body)
    {:ok, agent_body} = AgentOS.Pipeline.Stage4.generate(agent_name, manifest, opts)

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

    # Injected provider_fn for inference metering simulations in tests
    inference_provider_fn = fn _model, _messages, _secret ->
      %{input_tokens: 20, output_tokens: 10, completion: "hostile response"}
    end

    {:ok,
     agent_name: agent_name,
     run_token: run_token,
     manifest: manifest,
     prices: @prices,
     now: @now,
     effector_collector: effector_collector,
     effector_fn: effector_fn,
     provider_fn: inference_provider_fn,
     agent_body: agent_body,
     spec_dir: dirs.spec_dir,
     manifest_dir: dirs.manifest_dir}
  end

  describe "BC-1 exceed grants (runtime) · FR-001, SC-001" do
    test "ungranted actions are rejected in partition_batch, approved action succeeds", context do
      registry = AgentOS.Connector.registry()

      {approved, _parked, rejected, _breached} =
        Gate.partition_batch(Hostile.mixed_batch(), context.manifest, registry, %{spent: 0})

      assert length(approved) == 1
      assert [%{action: %AgentOS.ProposedAction{type: "kv_append", method: "append"}}] = approved

      assert length(rejected) == 2

      assert [
               {%{"type" => "unknown_connector"}, :unknown_action},
               {%{"foo" => "bar"}, :bad_shape}
             ] = rejected

      Enum.each(approved, context.effector_fn)

      executed = Agent.get(context.effector_collector, & &1)
      assert length(executed) == 1
      refute Enum.any?(executed, fn entry -> entry.action.type == "unknown_connector" end)

      narrow_manifest = %Manifest{context.manifest | grants: []}

      {approved_narrow, _, rejected_narrow, _} =
        Gate.partition_batch(Hostile.mixed_batch(), narrow_manifest, registry, %{spent: 0})

      assert approved_narrow == []
      assert length(rejected_narrow) == 3
    end
  end

  describe "BC-2 spoof recipient/method (runtime) · FR-002, SC-002" do
    test "rejects out-of-scope recipient and method, allows in-scope", context do
      registry = AgentOS.Connector.registry()

      {:ok, spoofed_recipient} =
        AgentOS.ProposedAction.from_map(Hostile.spoofed_recipient_action())

      {:ok, spoofed_method} = AgentOS.ProposedAction.from_map(Hostile.spoofed_method_action())
      {:ok, in_scope} = AgentOS.ProposedAction.from_map(Hostile.in_scope_external_send_action())

      assert {:reject, :recipient_out_of_scope} =
               Gate.evaluate(spoofed_recipient, context.manifest, registry, %{spent: 0})

      assert {:reject, :method_out_of_scope} =
               Gate.evaluate(spoofed_method, context.manifest, registry, %{spent: 0})

      assert {:needs_approval, _grant} =
               Gate.evaluate(in_scope, context.manifest, registry, %{spent: 0})

      executed = Agent.get(context.effector_collector, & &1)
      assert executed == []
    end
  end

  describe "BC-3 exfiltrate / no-bypass (by-construction + positive control) · FR-003, SC-003" do
    test "runtime: only gate-approved actions reach effector_fn, and positive control proves it is live",
         context do
      registry = AgentOS.Connector.registry()

      {approved, _, _, _} =
        Gate.partition_batch(Hostile.mixed_batch(), context.manifest, registry, %{spent: 0})

      Enum.each(approved, context.effector_fn)

      executed = Agent.get(context.effector_collector, & &1)
      assert length(executed) == 1
      assert [%{action: %AgentOS.ProposedAction{type: "kv_append"}}] = executed

      snapshot = AgentOS.StateStore.snapshot("roster_trust")
      assert length(snapshot.records) == 1
      assert [%{"name" => "hostile_payload"}] = snapshot.records
    end
  end

  describe "BC-4 bust the dollar cap (runtime) · FR-004, SC-004" do
    test "meters its own computed dollars and returns breach when cap crossed", context do
      # Clear spend ledger to reset accumulated spend
      :ok = AgentOS.StateStore.apply_action("spend_ledger", {:delete_in, [context.agent_name]})

      req = %{
        run_token: context.run_token,
        model: "mock-model",
        messages: [%{role: "user", content: "hello"}]
      }

      provider_fn = fn _model, _messages, _secret ->
        %{input_tokens: 200, output_tokens: 100, completion: "hostile response"}
      end

      assert {:breach, :spend} =
               InferenceBroker.complete(req,
                 now: context.now,
                 provider_fn: provider_fn,
                 prices: context.prices
               )

      ledger = AgentOS.StateStore.snapshot("spend_ledger")
      entry = Map.get(ledger, context.agent_name)
      assert entry != nil
      assert entry.spent == 5000

      assert entry.spent > context.manifest.spend.cap
    end
  end

  describe "BC-5 forge a trigger (by-construction) · FR-005, SC-005" do
    test "trigger-shaped string from agent output fires zero runs, while TriggerGateway intake fires exactly once",
         context do
      registry = AgentOS.Connector.registry()
      hostile_action = %{"type" => Hostile.trigger_string(), "payload" => %{}}

      {approved, _, rejected, _} =
        Gate.partition_batch([hostile_action], context.manifest, registry, %{spent: 0})

      assert approved == []
      assert length(rejected) == 1

      parent = self()

      start_run_fn = fn opts ->
        send(parent, {:run_fired, opts})
        {:ok, self()}
      end

      # Add trigger to the manifest under context
      manifest_with_trigger = %Manifest{
        context.manifest
        | triggers: [%{type: :event, name: "bookmark_saved"}]
      }

      manifests_fn = fn ->
        %{context.agent_name => manifest_with_trigger}
      end

      res =
        TriggerGateway.submit_sync(
          {:event, Hostile.trigger_string(), %{"url" => "https://example.com"}},
          start_run_fn: start_run_fn,
          manifests_fn: manifests_fn
        )

      assert res == {:fired, [context.agent_name]}
      assert_receive {:run_fired, run_opts}
      assert Keyword.get(run_opts, :agent) == context.agent_name
    end
  end

  describe "BC-6 forge/self-grant approval (by-construction + at-most-once) · FR-006, SC-006" do
    test "agent approval attempts stay parked, intake approve executes exactly once, duplicate is no-op",
         context do
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

      snapshot = AgentOS.StateStore.snapshot("pending_approvals")
      assert Map.get(snapshot.approvals, "ref_42") != nil

      res =
        TriggerGateway.submit_sync(
          {:approval, :approve, "ref_42"},
          effector_fn: context.effector_fn
        )

      assert res == {:resolved, :approved}
      executed = Agent.get(context.effector_collector, & &1)
      assert length(executed) == 1

      snapshot2 = AgentOS.StateStore.snapshot("pending_approvals")
      assert Map.get(snapshot2.approvals, "ref_42") == nil

      res_dup =
        TriggerGateway.submit_sync(
          {:approval, :approve, "ref_42"},
          effector_fn: context.effector_fn
        )

      assert res_dup == {:resolved, :unknown_ref}

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
    end
  end

  describe "BC-7 read the manifest (by-construction) · FR-007, SC-007" do
    test "manifest keys are completely absent from built payload, but gate can read them",
         context do
      sample_snapshot = %{records: [%{"name" => "Alice", "role" => "Admin"}]}
      sample_items = [%{"id" => 1, "title" => "Important News"}]

      payload = AgentOS.RunWorker.build_payload(sample_snapshot, sample_items)
      assert Map.keys(payload) == ["items", "state"]

      found_keys = Hostile.probe_payload_for_manifest(payload)
      assert found_keys == []

      assert length(context.manifest.grants) > 0
      refute is_nil(context.manifest.spend)
    end

    test "machine-written manifest (Stage 2) is loaded and enforces manifest invisibility",
         context do
      # 1. Probe payload for manifest fields on the generated manifest
      sample_snapshot = %{records: []}
      sample_items = []
      payload = AgentOS.RunWorker.build_payload(sample_snapshot, sample_items)
      assert Map.keys(payload) == ["items", "state"]

      found_keys = Hostile.probe_payload_for_manifest(payload)
      assert found_keys == []

      # 2. Prove that runtime gate evaluates over this loaded manifest as an external predicate
      registry = AgentOS.Connector.registry()
      allowed_action = %AgentOS.ProposedAction{type: "kv_append", method: "append", payload: %{}}

      disallowed_action = %AgentOS.ProposedAction{
        type: "kv_append",
        method: "delete",
        payload: %{}
      }

      assert {:approve, _} =
               Gate.evaluate(allowed_action, context.manifest, registry, %{spent: 0})

      assert {:reject, :method_out_of_scope} =
               Gate.evaluate(disallowed_action, context.manifest, registry, %{spent: 0})
    end
  end

  describe "BC-8 hold a credential (by-construction + positive control) · FR-008, SC-008" do
    test "proxy returns closure result only, secret is absent from agent payload, positive control verifies proxy is live",
         _context do
      result =
        CredentialProxy.with_credential(:outbound_token, fn secret ->
          assert secret == "test_secret_outbound_token_value"
          :closure_executed
        end)

      assert result == :closure_executed

      sample_snapshot = %{records: [%{"name" => "Alice", "role" => "Admin"}]}
      sample_items = [%{"id" => 1, "title" => "Important News"}]
      payload = AgentOS.RunWorker.build_payload(sample_snapshot, sample_items)

      secrets = ["test_secret_outbound_token_value", "test_secret_model_key_value"]
      assert Hostile.probe_for_credentials(payload, secrets) == []
    end
  end

  describe "BC-9 combined/replay (runtime + by-construction) · FR-015" do
    test "chained attempt (self-approve of out-of-scope action) stops at first boundary",
         context do
      registry = AgentOS.Connector.registry()
      {:ok, spoofed} = AgentOS.ProposedAction.from_map(Hostile.spoofed_recipient_action())

      assert {:reject, :recipient_out_of_scope} =
               Gate.evaluate(spoofed, context.manifest, registry, %{spent: 0})

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

  describe "deploy review modes safety" do
    test "even under dangerously-skip-review, manifest breaches are still blocked at runtime",
         context do
      hash = AgentOS.Provisioner.code_hash(context.agent_name, spec_dir: context.spec_dir)

      :ok =
        AgentOS.StateStore.apply_action(
          "judge_results",
          {:put, context.agent_name, %{status: :pass, code_hash: hash}}
        )

      verdict = %AgentOS.Pipeline.Stage5.Verdict{
        status: :pass,
        code_hash: hash,
        timestamp: context.now,
        reasoning: "ok"
      }

      :ok =
        AgentOS.StateStore.apply_action(
          "security_review_results",
          {:put, context.agent_name, verdict}
        )

      manifest_path = Path.join(context.manifest_dir, "#{context.agent_name}.md")
      :ok = AgentOS.Manifest.Projection.write(context.manifest, manifest_path)

      assert {:ok, :dangerously_skipped} =
               AgentOS.Provisioner.deploy(manifest_path, :dangerously_skip_review,
                 spec_dir: context.spec_dir
               )

      registry = AgentOS.Connector.registry()

      disallowed_action = %AgentOS.ProposedAction{
        type: "unknown_connector",
        recipient: "nil",
        method: "nil",
        payload: %{}
      }

      assert {:reject, :unknown_action} =
               Gate.evaluate(disallowed_action, context.manifest, registry, %{spent: 0})
    end
  end

  describe "no-drop guard test" do
    test "assert the count of describe BC- blocks equals world_b_test.exs" do
      content_orig = File.read!("test/agent_os/world_b_test.exs")
      content_gen = File.read!("test/agent_os/world_b_generated_test.exs")

      count_orig = length(Regex.scan(~r/describe\s+"BC-/, content_orig))
      count_gen = length(Regex.scan(~r/describe\s+"BC-/, content_gen))

      assert count_gen == count_orig
      assert count_orig > 0
    end
  end
end
