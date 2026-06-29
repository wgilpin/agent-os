defmodule AgentOS.InferenceBrokerTest do
  use ExUnit.Case, async: false

  alias AgentOS.InferenceBroker
  alias AgentOS.StateStore
  alias AgentOS.Manifest
  alias AgentOS.Manifest.Spend

  setup do
    # Start unique StateStore for isolation
    tmp_spend =
      Path.join(
        System.tmp_dir!(),
        "spend_ledger_broker_test_#{System.unique_integer([:positive])}.term"
      )

    on_exit(fn -> File.rm(tmp_spend) end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})

    # Start the InferenceBroker and CredentialProxy GenServers
    start_supervised!(AgentOS.CredentialProxy)
    start_supervised!(InferenceBroker)

    agent_name = "test_agent"

    manifest = %Manifest{
      purpose: "Test agent",
      owner: "human",
      supervision: "restart-once-and-alert",
      grants: [],
      spend: %Spend{cap: 1000, window: :daily, on_breach: :kill},
      mounts: [],
      triggers: []
    }

    run_token = "test_run_token"
    :ok = InferenceBroker.register(run_token, agent_name, manifest)

    prices = %{
      "mock-model" => %{input: 10, output: 30}
    }

    now = ~U[2026-06-29 12:00:00Z]

    {:ok,
     run_token: run_token, agent_name: agent_name, manifest: manifest, prices: prices, now: now}
  end

  test "T006 (a) price math: exact micro-dollars summed into ledger", context do
    req = %{
      run_token: context.run_token,
      model: "mock-model",
      messages: [%{role: "user", content: "hello"}]
    }

    provider_fn = fn _model, _messages, _secret ->
      %{input_tokens: 20, output_tokens: 10, completion: "hello response"}
    end

    # expected cost: 20 * 10 + 10 * 30 = 500 micro-dollars
    assert {:ok, %{completion: "hello response"}} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn,
               prices: context.prices
             )

    ledger = StateStore.snapshot("spend_ledger")
    entry = Map.get(ledger, context.agent_name)
    assert entry != nil
    assert entry.spent == 500
  end

  test "T006 (b) visibility: success result has only :completion key", context do
    req = %{
      run_token: context.run_token,
      model: "mock-model",
      messages: [%{role: "user", content: "hello"}]
    }

    provider_fn = fn _model, _messages, _secret ->
      %{input_tokens: 20, output_tokens: 10, completion: "hello response"}
    end

    assert {:ok, res} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn,
               prices: context.prices
             )

    assert Map.keys(res) == [:completion]
  end

  test "T006 (c) fail-closed: unpriced model and unknown token", context do
    # 1. Unpriced model
    req_unpriced = %{
      run_token: context.run_token,
      model: "unpriced-model",
      messages: [%{role: "user", content: "hello"}]
    }

    provider_fn = fn _model, _messages, _secret ->
      send(self(), :provider_called)
      %{input_tokens: 20, output_tokens: 10, completion: "hello response"}
    end

    assert {:error, :unpriced_model} =
             InferenceBroker.complete(req_unpriced,
               now: context.now,
               provider_fn: provider_fn,
               prices: context.prices
             )

    refute_received :provider_called

    # 2. Unknown run token
    req_unknown = %{
      run_token: "unknown_token",
      model: "mock-model",
      messages: [%{role: "user", content: "hello"}]
    }

    assert {:error, :unknown_run_token} =
             InferenceBroker.complete(req_unknown,
               now: context.now,
               provider_fn: provider_fn,
               prices: context.prices
             )

    refute_received :provider_called
  end

  test "T006 (d) one-call overshoot: call that crosses is metered and breaches", context do
    req = %{
      run_token: context.run_token,
      model: "mock-model",
      messages: [%{role: "user", content: "hello"}]
    }

    # Seed spent at 600 (under 1000 cap)
    :ok =
      StateStore.apply_action(
        "spend_ledger",
        {:put, context.agent_name, %{spent: 600, window_start: context.now}}
      )

    provider_fn = fn _model, _messages, _secret ->
      send(self(), :provider_called)
      %{input_tokens: 20, output_tokens: 10, completion: "hello response"}
    end

    # cost is 500. 600 + 500 = 1100 >= 1000 (breach).
    # provider_fn should be invoked once.
    assert {:breach, :spend} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn,
               prices: context.prices
             )

    assert_received :provider_called

    # ledger spent should exceed cap by exactly the call cost (600 + 500 = 1100)
    ledger = StateStore.snapshot("spend_ledger")
    entry = Map.get(ledger, context.agent_name)
    assert entry.spent == 1100
  end

  test "T006 (e) pre-check refusal: spent >= cap blocks provider call", context do
    req = %{
      run_token: context.run_token,
      model: "mock-model",
      messages: [%{role: "user", content: "hello"}]
    }

    # Seed spent at 1000 (equal to cap)
    :ok =
      StateStore.apply_action(
        "spend_ledger",
        {:put, context.agent_name, %{spent: 1000, window_start: context.now}}
      )

    provider_fn = fn _model, _messages, _secret ->
      send(self(), :provider_called)
      %{input_tokens: 20, output_tokens: 10, completion: "hello"}
    end

    assert {:breach, :spend} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn,
               prices: context.prices
             )

    refute_received :provider_called
  end
end
