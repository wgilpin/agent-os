defmodule AgentOS.InferenceBrokerOpenAITest do
  # Feature 046 / US2: the OpenAI-compatible /v1/chat/completions surface authenticates
  # on the Bearer run token and maps onto the SAME pricing/metering/cap/kill path as the
  # native /v1/inference envelope. No live model (Constitution IV): provider_fn is stubbed.
  use ExUnit.Case, async: false

  alias AgentOS.InferenceBroker
  alias AgentOS.StateStore
  alias AgentOS.Manifest
  alias AgentOS.Manifest.Spend

  # Stub provider that records each call and returns fixed usage (20/10 tokens ->
  # 500 micro-dollars at the test prices) plus an assistant message.
  defp recording_provider(test_pid) do
    fn model, _messages, _tools, _secret ->
      send(test_pid, {:provider_called, model})

      %{
        input_tokens: 20,
        output_tokens: 10,
        completion: "ok",
        message: %{"role" => "assistant", "content" => "ok"}
      }
    end
  end

  defp setup_broker(cap) do
    tmp_spend =
      Path.join(System.tmp_dir!(), "spend_openai_#{System.unique_integer([:positive])}.db")

    tmp_transcript =
      Path.join(System.tmp_dir!(), "transcript_openai_#{System.unique_integer([:positive])}.db")

    on_exit(fn ->
      File.rm(tmp_spend)
      File.rm(tmp_transcript)
    end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})
    start_supervised!({StateStore, name: "action_transcript", path: tmp_transcript, initial: %{}})
    start_supervised!(AgentOS.CredentialProxy)
    start_supervised!(InferenceBroker)

    agent_name = "openai_agent_#{System.unique_integer([:positive])}"

    manifest = %Manifest{
      purpose: "OpenAI surface test agent",
      owner: "human",
      supervision: "restart-once-and-alert",
      grants: [],
      spend: %Spend{cap: cap, window: :daily, on_breach: :kill},
      mounts: [],
      triggers: []
    }

    run_token = "openai_run_#{System.unique_integer([:positive])}"
    :ok = InferenceBroker.register(run_token, agent_name, manifest)

    %{
      run_token: run_token,
      agent_name: agent_name,
      prices: %{"mock-model" => %{input: 10_000_000, output: 30_000_000}},
      now: ~U[2026-07-12 12:00:00Z]
    }
  end

  defp request(model \\ "mock-model") do
    %{
      "model" => model,
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "tools" => []
    }
  end

  describe "metering parity (US2-1, US2-4 / SC-003)" do
    test "valid token + priced model + under cap -> 200-shaped completion, ledger += exact cost" do
      ctx = setup_broker(10_000)

      assert {:ok, completion} =
               InferenceBroker.complete_openai(request(), ctx.run_token,
                 now: ctx.now,
                 provider_fn: recording_provider(self()),
                 prices: ctx.prices
               )

      assert_received {:provider_called, "mock-model"}
      # OpenAI-shaped response the framework accepts.
      assert %{"choices" => [%{"message" => msg, "finish_reason" => "stop"}], "usage" => usage} =
               completion

      assert msg["content"] == "ok"
      assert usage["prompt_tokens"] == 20 and usage["completion_tokens"] == 10

      entry = StateStore.snapshot("spend_ledger") |> Map.get(ctx.agent_name)
      assert entry.spent == 500
    end

    test "N sequential calls -> N discrete ledger writes reconciling call-for-call" do
      ctx = setup_broker(100_000)
      provider = recording_provider(self())

      for _ <- 1..3 do
        assert {:ok, _} =
                 InferenceBroker.complete_openai(request(), ctx.run_token,
                   now: ctx.now,
                   provider_fn: provider,
                   prices: ctx.prices
                 )
      end

      entry = StateStore.snapshot("spend_ledger") |> Map.get(ctx.agent_name)
      assert entry.spent == 1500
    end
  end

  describe "auth rejection (US2-2)" do
    test "missing/invalid bearer token -> unknown_run_token, no provider call, no spend" do
      ctx = setup_broker(10_000)

      assert {:error, :unknown_run_token} =
               InferenceBroker.complete_openai(request(), nil,
                 now: ctx.now,
                 provider_fn: recording_provider(self()),
                 prices: ctx.prices
               )

      refute_received {:provider_called, _}
      assert StateStore.snapshot("spend_ledger") |> Map.get(ctx.agent_name) == nil
    end

    test "unknown token value -> unknown_run_token, no provider call" do
      ctx = setup_broker(10_000)

      assert {:error, :unknown_run_token} =
               InferenceBroker.complete_openai(request(), "not-a-real-token",
                 now: ctx.now,
                 provider_fn: recording_provider(self()),
                 prices: ctx.prices
               )

      refute_received {:provider_called, _}
    end
  end

  describe "cap enforcement + kill-on-breach (US2-3)" do
    test "pre-existing spent >= cap -> breach, provider never called" do
      ctx = setup_broker(400)
      # Seed the ledger already at/over the cap.
      StateStore.apply_action(
        "spend_ledger",
        {:put, ctx.agent_name, %{spent: 400, window_start: ctx.now}}
      )

      assert {:breach, :spend} =
               InferenceBroker.complete_openai(request(), ctx.run_token,
                 now: ctx.now,
                 provider_fn: recording_provider(self()),
                 prices: ctx.prices
               )

      refute_received {:provider_called, _}
    end

    test "post-meter call crosses the cap -> breach (kill-on-breach)" do
      # cap 500; one call costs exactly 500 -> new_spent (500) >= cap -> breach.
      ctx = setup_broker(500)

      assert {:breach, :spend} =
               InferenceBroker.complete_openai(request(), ctx.run_token,
                 now: ctx.now,
                 provider_fn: recording_provider(self()),
                 prices: ctx.prices
               )

      # The call happened and was metered before the breach was detected.
      assert_received {:provider_called, _}
      entry = StateStore.snapshot("spend_ledger") |> Map.get(ctx.agent_name)
      assert entry.spent == 500
    end
  end

  describe "input validation" do
    test "unpriced model -> unpriced_model" do
      ctx = setup_broker(10_000)

      assert {:error, :unpriced_model} =
               InferenceBroker.complete_openai(request("no-such-model"), ctx.run_token,
                 now: ctx.now,
                 provider_fn: recording_provider(self()),
                 prices: ctx.prices
               )
    end

    test "streaming request -> unsupported (clean refusal)" do
      ctx = setup_broker(10_000)
      req = Map.put(request(), "stream", true)

      assert {:error, :unsupported} =
               InferenceBroker.complete_openai(req, ctx.run_token,
                 now: ctx.now,
                 provider_fn: recording_provider(self()),
                 prices: ctx.prices
               )
    end
  end

  describe "UDS HTTP route + Bearer parsing" do
    setup do
      # start_broker_uds! starts only the broker + credential proxy; the ledger stores
      # and their registry must exist first (do_complete_openai reads the spend ledger).
      tmp_spend =
        Path.join(System.tmp_dir!(), "spend_uds_#{System.unique_integer([:positive])}.db")

      tmp_transcript =
        Path.join(System.tmp_dir!(), "transcript_uds_#{System.unique_integer([:positive])}.db")

      on_exit(fn ->
        File.rm(tmp_spend)
        File.rm(tmp_transcript)
      end)

      start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
      start_supervised!({StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})

      start_supervised!(
        {StateStore, name: "action_transcript", path: tmp_transcript, initial: %{}}
      )

      sock =
        AgentOS.TestHelper.start_broker_uds!(fn _model, _messages, _tools, _secret ->
          %{
            input_tokens: 20,
            output_tokens: 10,
            completion: "pong",
            message: %{"role" => "assistant", "content" => "pong"}
          }
        end)

      %{sock: sock}
    end

    test "valid Bearer token -> 200 OpenAI completion", %{sock: sock} do
      agent_name = "uds_openai_#{System.unique_integer([:positive])}"

      manifest = %Manifest{
        purpose: "UDS OpenAI test",
        owner: "human",
        supervision: "restart-once-and-alert",
        grants: [],
        spend: %Spend{cap: 100_000, window: :daily, on_breach: :kill},
        mounts: [],
        triggers: []
      }

      token = "uds_run_#{System.unique_integer([:positive])}"
      :ok = InferenceBroker.register(token, agent_name, manifest)

      # Price the model the broker resolves. effective_model is nil here, so the
      # request model is used; register a price for it via app env override.
      prev = Application.get_env(:agent_os, :inference_prices)
      Application.put_env(:agent_os, :inference_prices, %{"mock-model" => %{input: 1, output: 1}})
      on_exit(fn -> Application.put_env(:agent_os, :inference_prices, prev) end)

      {status, body} =
        AgentOS.TestHelper.chat_completions_uds(
          sock,
          %{"model" => "mock-model", "messages" => [%{"role" => "user", "content" => "ping"}]},
          run_token: token
        )

      assert status == 200
      assert %{"choices" => [%{"message" => %{"content" => "pong"}}]} = body
    end

    test "missing Authorization header -> 401", %{sock: sock} do
      {status, body} =
        AgentOS.TestHelper.chat_completions_uds(
          sock,
          %{"model" => "mock-model", "messages" => []},
          run_token: nil
        )

      assert status == 401
      assert body["error"] == "unknown_run_token"
    end
  end
end
