defmodule AgentOS.ExecutionModeTest do
  use ExUnit.Case, async: false

  alias AgentOS.ExecutionMode
  alias AgentOS.InferenceBroker
  alias AgentOS.StateStore
  alias AgentOS.Manifest
  alias AgentOS.Manifest.Spend

  # --- T005: typed value round-trips (no broker needed) --------------------

  describe "T005 typed value" do
    test "parse/1 round-trips both valid values" do
      assert {:ok, :deterministic} = ExecutionMode.parse("deterministic")
      assert {:ok, :deterministic} = ExecutionMode.parse(:deterministic)
      assert {:ok, :inference} = ExecutionMode.parse("inference")
      assert {:ok, :inference} = ExecutionMode.parse(:inference)
      # prose tolerance for the spec's "inference-based" wording
      assert {:ok, :inference} = ExecutionMode.parse("inference-based")
    end

    test "parse/1 rejects any third value, a bare map, or a bare string" do
      assert {:error, :invalid_mode} = ExecutionMode.parse("hybrid")
      assert {:error, :invalid_mode} = ExecutionMode.parse(:llm)
      assert {:error, :invalid_mode} = ExecutionMode.parse(%{"mode" => "deterministic"})
      assert {:error, :invalid_mode} = ExecutionMode.parse(nil)
    end

    test "to_json/from_json round-trip preserves mode and rationale" do
      mode = %ExecutionMode{mode: :deterministic, rationale: "fixed notification"}
      json = mode |> ExecutionMode.to_json() |> Jason.encode!()

      assert {:ok, %ExecutionMode{mode: :deterministic, rationale: "fixed notification"}} =
               ExecutionMode.from_json(json)
    end

    test "values/0 lists exactly the two modes" do
      assert ExecutionMode.values() == [:deterministic, :inference]
    end
  end

  # --- T015: classification via provider_fn stub + sidecar round-trip ------

  describe "T015 classify + sidecar" do
    setup do
      tmp_spend =
        Path.join(System.tmp_dir!(), "spend_em_#{System.unique_integer([:positive])}.db")

      tmp_transcript =
        Path.join(System.tmp_dir!(), "at_em_#{System.unique_integer([:positive])}.db")

      spec_dir = Path.join(System.tmp_dir!(), "em_agents_#{System.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm(tmp_spend)
        File.rm(tmp_transcript)
        File.rm_rf(spec_dir)
      end)

      start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
      start_supervised!({StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})

      start_supervised!(
        {StateStore, name: "action_transcript", path: tmp_transcript, initial: %{}}
      )

      start_supervised!(AgentOS.CredentialProxy)
      start_supervised!(InferenceBroker)

      manifest = %Manifest{
        purpose: "send a hard-coded greeting on trigger",
        owner: "human",
        supervision: "restart-once-and-alert",
        grants: [],
        spend: %Spend{cap: 1_000_000_000, window: :daily, on_breach: :kill},
        mounts: [],
        triggers: []
      }

      run_token = "em_token"
      :ok = InferenceBroker.register(run_token, "orchestrator", manifest)

      prices = %{"mock-model" => %{input: 10_000_000, output: 30_000_000}}
      now = ~U[2026-07-07 12:00:00Z]

      {:ok,
       run_token: run_token, manifest: manifest, prices: prices, now: now, spec_dir: spec_dir}
    end

    defp stub(json) do
      fn _model, _messages, _secret ->
        %{input_tokens: 5, output_tokens: 5, completion: json}
      end
    end

    test "fixed-action purpose classifies deterministic", ctx do
      json =
        ~s({"mode": "deterministic", "rationale": "fixed notification; no runtime reasoning"})

      assert {:ok, %ExecutionMode{mode: :deterministic}} =
               ExecutionMode.classify("greeter", ctx.manifest,
                 run_token: ctx.run_token,
                 model: "mock-model",
                 provider_fn: stub(json),
                 prices: ctx.prices,
                 now: ctx.now
               )
    end

    test "reasoning purpose classifies inference", ctx do
      json = ~s({"mode": "inference", "rationale": "summarizes incoming message"})

      assert {:ok, %ExecutionMode{mode: :inference}} =
               ExecutionMode.classify("summarizer", ctx.manifest,
                 run_token: ctx.run_token,
                 model: "mock-model",
                 provider_fn: stub(json),
                 prices: ctx.prices,
                 now: ctx.now
               )
    end

    test "unparseable classifier output defaults to inference", ctx do
      assert {:ok, %ExecutionMode{mode: :inference}} =
               ExecutionMode.classify("weird", ctx.manifest,
                 run_token: ctx.run_token,
                 model: "mock-model",
                 provider_fn: stub("not json at all"),
                 prices: ctx.prices,
                 now: ctx.now
               )
    end

    test "an invalid third mode value defaults to inference", ctx do
      json = ~s({"mode": "hybrid", "rationale": "confused"})

      assert {:ok, %ExecutionMode{mode: :inference}} =
               ExecutionMode.classify("confused", ctx.manifest,
                 run_token: ctx.run_token,
                 model: "mock-model",
                 provider_fn: stub(json),
                 prices: ctx.prices,
                 now: ctx.now
               )
    end

    test "store/load sidecar round-trip", ctx do
      mode = %ExecutionMode{mode: :deterministic, rationale: "fixed notification"}
      assert :ok = ExecutionMode.store("greeter", mode, spec_dir: ctx.spec_dir)
      assert {:ok, ^mode} = ExecutionMode.load("greeter", spec_dir: ctx.spec_dir)

      # sidecar exists at the expected path
      assert File.exists?(Path.join([ctx.spec_dir, "greeter", "execution_mode.json"]))
    end

    test "load/2 on a missing file returns the pre-040 inference default", ctx do
      assert {:ok, %ExecutionMode{mode: :inference, rationale: "pre-040 agent (default)"}} =
               ExecutionMode.load("never_generated", spec_dir: ctx.spec_dir)
    end
  end
end
