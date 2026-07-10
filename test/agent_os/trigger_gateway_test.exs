defmodule AgentOS.TriggerGatewayTest do
  use ExUnit.Case, async: false

  alias AgentOS.TriggerGateway
  alias AgentOS.StateStore

  setup do
    tmp_approvals =
      Path.join(
        System.tmp_dir!(),
        "pending_approvals_#{System.unique_integer([:positive])}.db"
      )

    tmp_deployments =
      Path.join(
        System.tmp_dir!(),
        "deployments_#{System.unique_integer([:positive])}.db"
      )

    on_exit(fn ->
      try do
        File.rm(tmp_approvals)
        File.rm(tmp_deployments)
      rescue
        _ -> :ok
      end
    end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})

    start_supervised!(
      {StateStore, name: "pending_approvals", path: tmp_approvals, initial: %{approvals: %{}}}
    )

    # Dispatch is registry-gated since 041: seed the agents these tests fire as
    # deployed-active so the pre-existing fan-out assertions keep their intent.
    start_supervised!({StateStore, name: "deployments", path: tmp_deployments, initial: %{}})

    :ok =
      AgentOS.DeploymentRegistry.record_deployment(
        "discovery",
        "test/fixtures/manifests/discovery.md",
        :reviewed_human
      )

    :ok =
      AgentOS.DeploymentRegistry.record_deployment(
        "no_msg",
        "manifests/no_msg.md",
        :reviewed_human
      )

    {:ok, tmp_approvals: tmp_approvals}
  end

  test "event matching manifest triggers fires exactly once per match" do
    # Define mock manifests
    mock_manifests = %{
      "discovery" => %AgentOS.Manifest{
        purpose: "test",
        owner: "human",
        supervision: "none",
        grants: [],
        spend: %AgentOS.Manifest.Spend{cap: 1000, window: :daily, on_breach: :kill},
        triggers: [%{type: :event, name: "bookmark_saved"}]
      },
      "other_agent" => %AgentOS.Manifest{
        purpose: "test",
        owner: "human",
        supervision: "none",
        grants: [],
        spend: %AgentOS.Manifest.Spend{cap: 1000, window: :daily, on_breach: :kill},
        triggers: [%{type: :time, at: "07:00"}]
      }
    }

    # Agent process capturing calls to start_run
    parent = self()

    start_run_fn = fn opts ->
      send(parent, {:start_run, opts})
      {:ok, self()}
    end

    manifests_fn = fn -> mock_manifests end
    payload = %{"url" => "https://example.com"}

    # Call submit_sync
    res =
      TriggerGateway.submit_sync(
        {:event, "bookmark_saved", payload},
        start_run_fn: start_run_fn,
        manifests_fn: manifests_fn
      )

    assert res == {:fired, ["discovery"]}

    # Assert start_run was called with correct options
    assert_receive {:start_run, run_opts}
    assert Keyword.get(run_opts, :trigger) == "event:bookmark_saved"
    assert Keyword.get(run_opts, :trigger_input) == payload
    assert Keyword.get(run_opts, :agent) == "discovery"

    # Ensure other_agent did not fire
    refute_receive {:start_run, _}
  end

  test "unlisted event fires nothing (default deny)" do
    mock_manifests = %{
      "discovery" => %AgentOS.Manifest{
        purpose: "test",
        owner: "human",
        supervision: "none",
        grants: [],
        spend: %AgentOS.Manifest.Spend{cap: 1000, window: :daily, on_breach: :kill},
        triggers: [%{type: :event, name: "bookmark_saved"}]
      }
    }

    parent = self()

    start_run_fn = fn opts ->
      send(parent, {:start_run, opts})
      {:ok, self()}
    end

    manifests_fn = fn -> mock_manifests end
    payload = %{"url" => "https://example.com"}

    res =
      TriggerGateway.submit_sync(
        {:event, "some_other_event", payload},
        start_run_fn: start_run_fn,
        manifests_fn: manifests_fn
      )

    assert res == {:fired, []}
    refute_receive {:start_run, _}
  end

  test "two identical events result in two captures (not collapsed)" do
    mock_manifests = %{
      "discovery" => %AgentOS.Manifest{
        purpose: "test",
        owner: "human",
        supervision: "none",
        grants: [],
        spend: %AgentOS.Manifest.Spend{cap: 1000, window: :daily, on_breach: :kill},
        triggers: [%{type: :event, name: "bookmark_saved"}]
      }
    }

    parent = self()

    start_run_fn = fn opts ->
      send(parent, {:start_run, opts})
      {:ok, self()}
    end

    manifests_fn = fn -> mock_manifests end
    payload = %{"url" => "https://example.com"}

    res1 =
      TriggerGateway.submit_sync(
        {:event, "bookmark_saved", payload},
        start_run_fn: start_run_fn,
        manifests_fn: manifests_fn
      )

    res2 =
      TriggerGateway.submit_sync(
        {:event, "bookmark_saved", payload},
        start_run_fn: start_run_fn,
        manifests_fn: manifests_fn
      )

    assert res1 == {:fired, ["discovery"]}
    assert res2 == {:fired, ["discovery"]}

    assert_receive {:start_run, _}
    assert_receive {:start_run, _}
  end

  test "malformed event rejected at intake" do
    mock_manifests = %{}
    parent = self()
    start_run_fn = fn opts -> send(parent, {:start_run, opts}) end
    manifests_fn = fn -> mock_manifests end

    # Empty name
    assert {:rejected, :invalid_event_name} ==
             TriggerGateway.submit_sync(
               {:event, "", %{}},
               start_run_fn: start_run_fn,
               manifests_fn: manifests_fn
             )

    # Whitespace in name
    assert {:rejected, :invalid_event_name} ==
             TriggerGateway.submit_sync(
               {:event, "bookmark saved", %{}},
               start_run_fn: start_run_fn,
               manifests_fn: manifests_fn
             )

    # Tab in name
    assert {:rejected, :invalid_event_name} ==
             TriggerGateway.submit_sync(
               {:event, "bookmark\tsaved", %{}},
               start_run_fn: start_run_fn,
               manifests_fn: manifests_fn
             )

    refute_receive {:start_run, _}
  end

  test "message to a message-triggered agent fires" do
    mock_manifests = %{
      "discovery" => %AgentOS.Manifest{
        purpose: "test",
        owner: "human",
        supervision: "none",
        grants: [],
        spend: %AgentOS.Manifest.Spend{cap: 1000, window: :daily, on_breach: :kill},
        triggers: [%{type: :message}]
      },
      "no_msg" => %AgentOS.Manifest{
        purpose: "test",
        owner: "human",
        supervision: "none",
        grants: [],
        spend: %AgentOS.Manifest.Spend{cap: 1000, window: :daily, on_breach: :kill},
        triggers: []
      }
    }

    parent = self()

    start_run_fn = fn opts ->
      send(parent, {:start_run, opts})
      {:ok, self()}
    end

    manifests_fn = fn -> mock_manifests end

    # 1. Message to a message-triggered agent fires
    res =
      TriggerGateway.submit_sync(
        {:message, "discovery", "hello"},
        start_run_fn: start_run_fn,
        manifests_fn: manifests_fn
      )

    assert res == {:fired, ["discovery"]}
    assert_receive {:start_run, run_opts}
    assert Keyword.get(run_opts, :trigger) == "message"
    assert Keyword.get(run_opts, :trigger_input) == "hello"
    assert Keyword.get(run_opts, :agent) == "discovery"

    # 2. Message to an agent lacking message trigger is rejected
    res_no_msg =
      TriggerGateway.submit_sync(
        {:message, "no_msg", "hello"},
        start_run_fn: start_run_fn,
        manifests_fn: manifests_fn
      )

    assert res_no_msg == {:rejected, :no_message_trigger}
    refute_receive {:start_run, _}

    # 3. Message to unknown agent is rejected
    res_unknown =
      TriggerGateway.submit_sync(
        {:message, "unknown", "hello"},
        start_run_fn: start_run_fn,
        manifests_fn: manifests_fn
      )

    assert res_unknown == {:rejected, :unknown_agent}
    refute_receive {:start_run, _}
  end

  describe "approval-resume (User Story 3)" do
    test "parked ref + approve -> effector called once, entry removed, resolved approved" do
      # Seed pending_approvals
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
        StateStore.apply_action(
          "pending_approvals",
          {:put, :approvals,
           %{"ref_42" => %{ref: "ref_42", action: mock_action, grant: mock_grant}}}
        )

      parent = self()

      effector_fn = fn entry ->
        send(parent, {:effector_called, entry})
        :ok
      end

      # Call approval resume
      res =
        TriggerGateway.submit_sync(
          {:approval, :approve, "ref_42"},
          effector_fn: effector_fn
        )

      assert res == {:resolved, :approved}

      # Verify effector called
      assert_receive {:effector_called, %{action: ^mock_action, grant: ^mock_grant}}

      # Verify entry removed
      snapshot = StateStore.snapshot("pending_approvals")
      assert Map.get(snapshot.approvals, "ref_42") == nil

      # Second approval of the same ref -> resolved unknown_ref, effector not called again
      res_dup =
        TriggerGateway.submit_sync(
          {:approval, :approve, "ref_42"},
          effector_fn: effector_fn
        )

      assert res_dup == {:resolved, :unknown_ref}
      refute_receive {:effector_called, _}
    end

    test "parked ref + deny -> effector not called, entry removed, resolved denied" do
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
        StateStore.apply_action(
          "pending_approvals",
          {:put, :approvals,
           %{"ref_99" => %{ref: "ref_99", action: mock_action, grant: mock_grant}}}
        )

      parent = self()

      effector_fn = fn entry ->
        send(parent, {:effector_called, entry})
        :ok
      end

      res =
        TriggerGateway.submit_sync(
          {:approval, :deny, "ref_99"},
          effector_fn: effector_fn
        )

      assert res == {:resolved, :denied}
      refute_receive {:effector_called, _}

      snapshot = StateStore.snapshot("pending_approvals")
      assert Map.get(snapshot.approvals, "ref_99") == nil
    end

    test "unknown ref -> effector not called, resolved unknown_ref" do
      parent = self()
      effector_fn = fn entry -> send(parent, {:effector_called, entry}) end

      res =
        TriggerGateway.submit_sync(
          {:approval, :approve, "ref_unknown"},
          effector_fn: effector_fn
        )

      assert res == {:resolved, :unknown_ref}
      refute_receive {:effector_called, _}
    end

    test "deploy approval resumption records provenance and triggers start_run" do
      tmp_provenance =
        Path.join(System.tmp_dir!(), "provenance_#{System.unique_integer([:positive])}.db")

      on_exit(fn -> File.rm(tmp_provenance) end)

      start_supervised!({StateStore, name: "provenance", path: tmp_provenance, initial: %{}})

      # Start a dummy RunSupervisor so it doesn't crash on cast
      defmodule DummyRunSupervisor do
        use GenServer

        def start_link(_opts),
          do: GenServer.start_link(__MODULE__, nil, name: AgentOS.RunSupervisor)

        def init(_), do: {:ok, nil}
        def handle_cast({:start_run, _}, state), do: {:noreply, state}
      end

      start_supervised!(DummyRunSupervisor)

      manifest_path = "test/fixtures/manifests/discovery.md"
      agent_name = "discovery"
      hash = "MOCKHASH123"

      action = %AgentOS.ProposedAction{
        type: "deploy",
        recipient: agent_name,
        method: manifest_path,
        payload: %{"review_mode" => "always_review", "hash" => hash}
      }

      grant = %AgentOS.Manifest.Grant{
        connector: "deploy",
        recipients: nil,
        methods: nil
      }

      :ok =
        StateStore.apply_action(
          "pending_approvals",
          {:put, :approvals,
           %{"ref_deploy_test" => %{ref: "ref_deploy_test", action: action, grant: grant}}}
        )

      res = TriggerGateway.submit_sync({:approval, :approve, "ref_deploy_test"})

      assert res == {:resolved, :approved}

      # Verify provenance recorded in provenance StateStore
      provenance = StateStore.snapshot("provenance")
      entry = Map.get(provenance, agent_name)
      assert entry.status == :reviewed_human
      assert entry.hash == hash

      # Verify entry removed from pending approvals
      snapshot = StateStore.snapshot("pending_approvals")
      assert Map.get(snapshot.approvals, "ref_deploy_test") == nil
    end
  end
end
