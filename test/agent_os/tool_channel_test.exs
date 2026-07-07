defmodule AgentOS.ToolChannelTest do
  @moduledoc """
  US1 — the direct tool-submission channel. Every test drives the gate with NO
  provider_fn configured: no model call occurs anywhere on this path. Dispositions
  are asserted from the ActionTranscript; spend from the ledger.
  """
  use ExUnit.Case, async: false

  alias AgentOS.InferenceBroker
  alias AgentOS.StateStore
  alias AgentOS.ActionTranscript
  alias AgentOS.Manifest
  alias AgentOS.Manifest.{Grant, Spend}

  setup do
    tmp_spend = Path.join(System.tmp_dir!(), "spend_tc_#{System.unique_integer([:positive])}.db")
    tmp_at = Path.join(System.tmp_dir!(), "at_tc_#{System.unique_integer([:positive])}.db")

    tmp_roster =
      Path.join(System.tmp_dir!(), "roster_tc_#{System.unique_integer([:positive])}.db")

    tmp_approvals =
      Path.join(System.tmp_dir!(), "appr_tc_#{System.unique_integer([:positive])}.db")

    on_exit(fn ->
      Enum.each([tmp_spend, tmp_at, tmp_roster, tmp_approvals], &File.rm/1)
    end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})
    start_supervised!({StateStore, name: "action_transcript", path: tmp_at, initial: %{}})

    start_supervised!(
      {StateStore, name: "roster_trust", path: tmp_roster, initial: %{records: []}}
    )

    start_supervised!(
      {StateStore, name: "pending_approvals", path: tmp_approvals, initial: %{approvals: %{}}}
    )

    start_supervised!(AgentOS.CredentialProxy)
    start_supervised!(InferenceBroker)

    agent = "chan_agent"

    manifest = %Manifest{
      purpose: "direct channel test agent",
      owner: "human",
      supervision: "restart-once-and-alert",
      grants: [
        %Grant{connector: "web_search", methods: nil, recipients: nil},
        %Grant{connector: "external_send", methods: nil, recipients: nil}
      ],
      spend: %Spend{cap: 1_000_000, window: :daily, on_breach: :kill},
      mounts: [],
      triggers: []
    }

    run_token = "chan_token"
    :ok = InferenceBroker.register(run_token, agent, manifest)
    now = ~U[2026-07-07 12:00:00Z]

    {:ok, agent: agent, manifest: manifest, run_token: run_token, now: now}
  end

  defp tool_call(id, name, args) do
    %{"id" => id, "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}
  end

  # --- T006: three-way disposition + metering + zero inference -------------

  test "T006 granted call is executed, recorded :granted, connector cost metered, zero inference spend",
       ctx do
    Application.put_env(:agent_os, :web_search_mock_fn, fn _q -> {:ok, "results"} end)
    on_exit(fn -> Application.delete_env(:agent_os, :web_search_mock_fn) end)

    assert {:ok, %{results: [res]}} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [tool_call("c1", "web_search", %{"query" => "hi"})]
               },
               now: ctx.now
             )

    assert res.disposition == "executed"
    assert res.name == "web_search"

    transcript = ActionTranscript.read(ctx.run_token)
    assert [%{kind: :granted, connector: "web_search"}] = transcript.entries

    # web_search cost is 1000 micro-dollars; ledger delta is exactly that (no inference).
    AgentOS.TestHelper.refute_inference_spend(ctx.agent, 1000)
  end

  test "granted call whose connector execution fails returns disposition \"error\"", ctx do
    # The rail records connector failures as :granted with an error result; the
    # channel must not let a deterministic body mistake that for success.
    Application.put_env(:agent_os, :web_search_mock_fn, fn _q -> {:error, :timeout} end)
    on_exit(fn -> Application.delete_env(:agent_os, :web_search_mock_fn) end)

    assert {:ok, %{results: [res]}} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [tool_call("c1", "web_search", %{"query" => "hi"})]
               },
               now: ctx.now
             )

    assert res.disposition == "error"
    assert res.content =~ "Error"

    transcript = ActionTranscript.read(ctx.run_token)

    assert [%{kind: :granted, connector: "web_search", result: %{"error" => _}}] =
             transcript.entries
  end

  test "T006 ungranted call is rejected and recorded, never executed", ctx do
    assert {:ok, %{results: [res]}} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [tool_call("c1", "discord_notify", %{"text" => "hi"})]
               },
               now: ctx.now
             )

    assert res.disposition == "rejected"

    transcript = ActionTranscript.read(ctx.run_token)

    assert [%{kind: :rejected, connector: "discord_notify", reason_code: :ungranted_connector}] =
             transcript.entries

    AgentOS.TestHelper.refute_inference_spend(ctx.agent, 0)
  end

  test "T006 approval-required call is parked, never executed", ctx do
    assert {:ok, %{results: [res]}} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [tool_call("c1", "external_send", %{"text" => "hi"})]
               },
               now: ctx.now
             )

    assert res.disposition == "parked"

    transcript = ActionTranscript.read(ctx.run_token)
    assert [%{kind: :parked, connector: "external_send"}] = transcript.entries

    approvals = StateStore.snapshot("pending_approvals")
    assert map_size(Map.get(approvals, :approvals, %{})) == 1

    # parked call executes nothing → no connector cost charged.
    AgentOS.TestHelper.refute_inference_spend(ctx.agent, 0)
  end

  # --- T007: rejection variety --------------------------------------------

  test "T007 granted-connector + ungranted-method → :ungranted_method", ctx do
    # Re-register with a method-scoped grant.
    manifest = %{
      ctx.manifest
      | grants: [%Grant{connector: "web_search", methods: ["search"], recipients: nil}]
    }

    :ok = InferenceBroker.register(ctx.run_token, ctx.agent, manifest)

    assert {:ok, %{results: [res]}} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [tool_call("c1", "web_search", %{"method" => "delete"})]
               },
               now: ctx.now
             )

    assert res.disposition == "rejected"

    assert [%{kind: :rejected, reason_code: :ungranted_method}] =
             ActionTranscript.read(ctx.run_token).entries
  end

  test "T007 unknown connector name → :unknown_connector", ctx do
    # Grant the name so it passes the grant check, but the registry has no such connector.
    manifest = %{
      ctx.manifest
      | grants: [%Grant{connector: "no_such_tool", methods: nil, recipients: nil}]
    }

    :ok = InferenceBroker.register(ctx.run_token, ctx.agent, manifest)

    assert {:ok, %{results: [res]}} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [tool_call("c1", "no_such_tool", %{})]
               },
               now: ctx.now
             )

    assert res.disposition == "rejected"

    assert [%{kind: :rejected, reason_code: :unknown_connector}] =
             ActionTranscript.read(ctx.run_token).entries
  end

  # --- T008: malformed request / empty submission --------------------------

  test "T008 malformed request (missing run_token / non-list tool_calls) → :bad_request", ctx do
    assert {:error, :bad_request} =
             InferenceBroker.submit_tool_calls(%{"tool_calls" => []}, now: ctx.now)

    assert {:error, :bad_request} =
             InferenceBroker.submit_tool_calls(
               %{"run_token" => ctx.run_token, "tool_calls" => "not-a-list"},
               now: ctx.now
             )

    # Nothing evaluated.
    assert ActionTranscript.read(ctx.run_token).entries == []
  end

  test "T008 empty tool_calls list is valid → empty results, empty transcript", ctx do
    assert {:ok, %{results: []}} =
             InferenceBroker.submit_tool_calls(
               %{"run_token" => ctx.run_token, "tool_calls" => []},
               now: ctx.now
             )

    assert ActionTranscript.read(ctx.run_token).entries == []
  end

  # --- T009: spend breach + response safety --------------------------------

  test "T009 cumulative cost crossing the cap → {:breach, :spend}", ctx do
    # cap 1500; web_search costs 1000; two calls = 2000 > cap → breach.
    manifest = %{
      ctx.manifest
      | grants: [%Grant{connector: "web_search", methods: nil, recipients: nil}],
        spend: %Spend{cap: 1500, window: :daily, on_breach: :kill}
    }

    :ok = InferenceBroker.register(ctx.run_token, ctx.agent, manifest)
    Application.put_env(:agent_os, :web_search_mock_fn, fn _q -> {:ok, "r"} end)
    on_exit(fn -> Application.delete_env(:agent_os, :web_search_mock_fn) end)

    assert {:breach, :spend} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [
                   tool_call("c1", "web_search", %{"query" => "a"}),
                   tool_call("c2", "web_search", %{"query" => "b"})
                 ]
               },
               now: ctx.now
             )
  end

  test "T009 response never exposes a credential, recipient allowlist, or spend cap", ctx do
    Application.put_env(:agent_os, :web_search_mock_fn, fn _q -> {:ok, "results"} end)
    on_exit(fn -> Application.delete_env(:agent_os, :web_search_mock_fn) end)

    assert {:ok, %{results: [res]}} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [tool_call("c1", "web_search", %{"query" => "hi"})]
               },
               now: ctx.now
             )

    # A per-call result carries only id/name/disposition/content — no capability data.
    assert Map.keys(res) |> Enum.sort() == [:content, :disposition, :id, :name]
    serialized = Jason.encode!(res)
    refute serialized =~ "1000000"
    refute serialized =~ "search_api_key"
    refute serialized =~ "recipients"
  end

  # --- Record-mode argument-schema validation ------------------------------
  # In :record mode the rail short-circuits to synthetic success without invoking
  # the connector. These tests prove it now validates decoded args against the
  # connector's tool declaration first, so the judge cannot be fooled by
  # argument-schema drift (e.g. inventing a parameter the connector never declared).

  test "record-mode call missing a required parameter is rejected, not recorded", ctx do
    :ok = InferenceBroker.register(ctx.run_token, ctx.agent, ctx.manifest, :record)

    # web_search declares required ["query"]; omitting it must be rejected.
    assert {:ok, %{results: [res]}} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [tool_call("c1", "web_search", %{"wrong" => "hi"})]
               },
               now: ctx.now
             )

    assert res.disposition == "rejected"
    assert res.content =~ "invalid arguments"

    assert [%{kind: :rejected, connector: "web_search", reason_code: :invalid_arguments}] =
             ActionTranscript.read(ctx.run_token).entries

    AgentOS.TestHelper.refute_inference_spend(ctx.agent, 0)
  end

  test "record-mode call with an undeclared parameter is rejected, not recorded", ctx do
    :ok = InferenceBroker.register(ctx.run_token, ctx.agent, ctx.manifest, :record)

    # "query" is present (required satisfied) but "bogus" is not a declared property.
    assert {:ok, %{results: [res]}} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [
                   tool_call("c1", "web_search", %{"query" => "hi", "bogus" => "x"})
                 ]
               },
               now: ctx.now
             )

    assert res.disposition == "rejected"
    assert res.content =~ "invalid arguments"

    assert [%{kind: :rejected, connector: "web_search", reason_code: :invalid_arguments}] =
             ActionTranscript.read(ctx.run_token).entries
  end

  test "record-mode call with valid args (plus method) records synthetic success", ctx do
    :ok = InferenceBroker.register(ctx.run_token, ctx.agent, ctx.manifest, :record)

    # "method" is not a declared property but the rail reads it for method gating,
    # so it must stay allowed alongside the declared "query".
    assert {:ok, %{results: [res]}} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [
                   tool_call("c1", "web_search", %{"query" => "hi", "method" => "search"})
                 ]
               },
               now: ctx.now
             )

    assert res.disposition == "executed"

    assert [%{kind: :granted, connector: "web_search", result: %{"status" => "recorded"}}] =
             ActionTranscript.read(ctx.run_token).entries

    AgentOS.TestHelper.refute_inference_spend(ctx.agent, 0)
  end

  # --- T010a: multi-call partial success -----------------------------------

  test "T010a a multi-call submission gates each call individually (partial success)", ctx do
    Application.put_env(:agent_os, :web_search_mock_fn, fn _q -> {:ok, "r"} end)
    on_exit(fn -> Application.delete_env(:agent_os, :web_search_mock_fn) end)

    assert {:ok, %{results: [ok_res, bad_res]}} =
             InferenceBroker.submit_tool_calls(
               %{
                 "run_token" => ctx.run_token,
                 "tool_calls" => [
                   tool_call("c1", "web_search", %{"query" => "hi"}),
                   tool_call("c2", "discord_notify", %{"text" => "nope"})
                 ]
               },
               now: ctx.now
             )

    assert ok_res.disposition == "executed"
    assert bad_res.disposition == "rejected"

    # Two independent transcript entries, in order.
    assert [
             %{kind: :granted, connector: "web_search"},
             %{kind: :rejected, connector: "discord_notify"}
           ] =
             ActionTranscript.read(ctx.run_token).entries
  end
end

defmodule AgentOS.ToolChannelUDSTest do
  @moduledoc "T010 — routing over the real UDS via start_broker_uds!/1."
  use ExUnit.Case, async: false

  alias AgentOS.InferenceBroker
  alias AgentOS.StateStore
  alias AgentOS.Manifest
  alias AgentOS.Manifest.{Grant, Spend}

  setup do
    tmp_spend = Path.join(System.tmp_dir!(), "spend_tcu_#{System.unique_integer([:positive])}.db")
    tmp_at = Path.join(System.tmp_dir!(), "at_tcu_#{System.unique_integer([:positive])}.db")

    tmp_roster =
      Path.join(System.tmp_dir!(), "roster_tcu_#{System.unique_integer([:positive])}.db")

    on_exit(fn -> Enum.each([tmp_spend, tmp_at, tmp_roster], &File.rm/1) end)

    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({StateStore, name: "spend_ledger", path: tmp_spend, initial: %{}})
    start_supervised!({StateStore, name: "action_transcript", path: tmp_at, initial: %{}})

    start_supervised!(
      {StateStore, name: "roster_trust", path: tmp_roster, initial: %{records: []}}
    )

    # start_broker_uds! brings up the broker WITH its UDS listener; a raising provider
    # proves no model call happens on the tool-call path.
    raising = fn _m, _msgs, _s -> raise "provider must not be called on the channel path" end
    sock = AgentOS.TestHelper.start_broker_uds!(raising)

    manifest = %Manifest{
      purpose: "uds channel test",
      owner: "human",
      supervision: "restart-once-and-alert",
      grants: [%Grant{connector: "web_search", methods: nil, recipients: nil}],
      spend: %Spend{cap: 1_000_000, window: :daily, on_breach: :kill},
      mounts: [],
      triggers: []
    }

    :ok = InferenceBroker.register("uds_token", "uds_agent", manifest)
    {:ok, sock: sock}
  end

  defp tool_call(id, name, args) do
    %{"id" => id, "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}
  end

  test "POST /v1/tool_calls returns disposition results over the UDS", ctx do
    Application.put_env(:agent_os, :web_search_mock_fn, fn _q -> {:ok, "results"} end)
    on_exit(fn -> Application.delete_env(:agent_os, :web_search_mock_fn) end)

    {status, body} =
      AgentOS.TestHelper.submit_tool_calls_uds(ctx.sock, %{
        "run_token" => "uds_token",
        "tool_calls" => [tool_call("c1", "web_search", %{"query" => "hi"})]
      })

    assert status == 200
    assert [%{"disposition" => "executed", "name" => "web_search"}] = body["results"]
  end

  test "POST /v1/tool_calls with unknown token → 401", ctx do
    {status, body} =
      AgentOS.TestHelper.submit_tool_calls_uds(ctx.sock, %{
        "run_token" => "not_registered",
        "tool_calls" => []
      })

    assert status == 401
    assert body["error"] == "unknown_run_token"
  end
end
