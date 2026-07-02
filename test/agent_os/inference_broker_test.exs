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
        "spend_ledger_broker_test_#{System.unique_integer([:positive])}.db"
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
      "mock-model" => %{input: 10_000_000, output: 30_000_000}
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

  test "T010 (f) HTTP Client error handling: timeout, network error, status error mappings",
       context do
    req = %{
      run_token: context.run_token,
      model: "mock-model",
      messages: [%{role: "user", content: "hello"}]
    }

    # 1. Timeout
    provider_fn_timeout = fn _model, _messages, _secret ->
      {:error, :timeout}
    end

    assert {:error, :timeout} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn_timeout,
               prices: context.prices
             )

    # 2. Network error
    provider_fn_network = fn _model, _messages, _secret ->
      {:error, :network_error}
    end

    assert {:error, :network_error} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn_network,
               prices: context.prices
             )

    # 3. HTTP status error
    provider_fn_status = fn _model, _messages, _secret ->
      {:error, {:http_status, 401}}
    end

    assert {:error, {:http_status, 401}} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn_status,
               prices: context.prices
             )

    # 4. Missing/Malformed usage
    provider_fn_missing = fn _model, _messages, _secret ->
      {:error, :missing_usage}
    end

    assert {:error, :missing_usage} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn_missing,
               prices: context.prices
             )

    # Ledger spent should remain 0 (no updates occurred for failed queries)
    ledger = StateStore.snapshot("spend_ledger")
    entry = Map.get(ledger, context.agent_name)
    assert entry == nil or entry.spent == 0
  end

  test "T021 (g) sub-micro-dollar pricing precision: no rounding to 0, rounds up to at least 1 micro-dollar",
       context do
    # Define a cheap model priced at 0.15 micro-dollars / token (150,000 pico-dollars / token)
    cheap_prices = %{
      "cheap-model" => %{input: 150_000, output: 600_000}
    }

    req = %{
      run_token: context.run_token,
      model: "cheap-model",
      messages: [%{role: "user", content: "hello"}]
    }

    # Case 1: 1000 input tokens. Cost: 1000 * 150,000 = 150,000,000 pico-dollars = 150 micro-dollars
    provider_fn = fn _model, _messages, _secret ->
      %{input_tokens: 1000, output_tokens: 0, completion: "hello response"}
    end

    assert {:ok, _} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn,
               prices: cheap_prices
             )

    ledger = StateStore.snapshot("spend_ledger")
    entry = Map.get(ledger, context.agent_name)
    assert entry.spent == 150

    # Reset ledger spent to 0
    StateStore.apply_action(
      "spend_ledger",
      {:put, context.agent_name, %{spent: 0, window_start: context.now}}
    )

    # Case 2: 1 input token. Cost: 1 * 150,000 = 150,000 pico-dollars. Rounds up to 1 micro-dollar.
    provider_fn_small = fn _model, _messages, _secret ->
      %{input_tokens: 1, output_tokens: 0, completion: "hello response"}
    end

    assert {:ok, _} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn_small,
               prices: cheap_prices
             )

    ledger2 = StateStore.snapshot("spend_ledger")
    entry2 = Map.get(ledger2, context.agent_name)
    assert entry2.spent == 1
  end

  test "get_configured_gid/0 resolves GID from environment, application config, or user fallback" do
    # Save original values
    orig_env = System.get_env("INFERENCE_GID")
    orig_config = Application.get_env(:agent_os, :inference_gid)

    on_exit(fn ->
      if orig_env,
        do: System.put_env("INFERENCE_GID", orig_env),
        else: System.delete_env("INFERENCE_GID")

      if orig_config,
        do: Application.put_env(:agent_os, :inference_gid, orig_config),
        else: Application.delete_env(:agent_os, :inference_gid)
    end)

    # 1. Test environment variable precedence
    System.put_env("INFERENCE_GID", "1234")
    assert InferenceBroker.get_configured_gid() == 1234

    # 2. Test configuration precedence when env is nil
    System.delete_env("INFERENCE_GID")
    Application.put_env(:agent_os, :inference_gid, 5678)
    assert InferenceBroker.get_configured_gid() == 5678

    # 3. Test configuration parsing of string/integer values
    Application.put_env(:agent_os, :inference_gid, "9012")
    assert InferenceBroker.get_configured_gid() == 9012

    # 4. Test dynamic fallback (should match primary user GID)
    Application.delete_env(:agent_os, :inference_gid)
    {id_out, 0} = System.cmd("id", ["-g"])
    expected_gid = String.trim(id_out) |> String.to_integer()
    assert InferenceBroker.get_configured_gid() == expected_gid
  end

  test "US1: socket permissions (0660) and GID ownership are correctly applied" do
    tmp_dir = Path.join(System.tmp_dir!(), "inference_us1_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    tmp_socket = Path.join(tmp_dir, "inference.sock")

    # Set up autostart config
    orig_autostart = Application.get_env(:agent_os, :autostart)
    Application.put_env(:agent_os, :autostart, true)
    Application.put_env(:agent_os, :inference_uds_path, tmp_socket)

    # Configure primary group as inference GID so chgrp succeeds
    {id_out, 0} = System.cmd("id", ["-g"])
    test_gid = String.trim(id_out) |> String.to_integer()
    Application.put_env(:agent_os, :inference_gid, test_gid)

    on_exit(fn ->
      File.rm_rf(tmp_dir)

      if orig_autostart != nil,
        do: Application.put_env(:agent_os, :autostart, orig_autostart),
        else: Application.delete_env(:agent_os, :autostart)

      Application.delete_env(:agent_os, :inference_uds_path)
      Application.delete_env(:agent_os, :inference_gid)
    end)

    # Start a fresh InferenceBroker to trigger init/1 with autostart: true
    # We must stop the default one running in setup first, or run it under a different ID
    # But start_supervised! takes care of restarting if it's already started under that name
    start_supervised!(%{
      id: InferenceBrokerTestInstance,
      start: {InferenceBroker, :start_link, [[name: InferenceBrokerTestInstance]]}
    })

    # Assert permissions and ownership on the socket
    assert File.exists?(tmp_socket)
    {:ok, stat} = File.stat(tmp_socket)
    perms = Bitwise.band(stat.mode, 0o777)
    assert perms == 0o660
    assert stat.gid == test_gid
  end

  test "US3: parent directory is restricted to 0700 permissions" do
    tmp_dir = Path.join(System.tmp_dir!(), "inference_us3_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    tmp_socket = Path.join(tmp_dir, "inference.sock")

    orig_autostart = Application.get_env(:agent_os, :autostart)
    Application.put_env(:agent_os, :autostart, true)
    Application.put_env(:agent_os, :inference_uds_path, tmp_socket)

    {id_out, 0} = System.cmd("id", ["-g"])
    test_gid = String.trim(id_out) |> String.to_integer()
    Application.put_env(:agent_os, :inference_gid, test_gid)

    on_exit(fn ->
      File.rm_rf(tmp_dir)

      if orig_autostart != nil,
        do: Application.put_env(:agent_os, :autostart, orig_autostart),
        else: Application.delete_env(:agent_os, :autostart)

      Application.delete_env(:agent_os, :inference_uds_path)
      Application.delete_env(:agent_os, :inference_gid)
    end)

    start_supervised!(%{
      id: InferenceBrokerTestInstanceUS3,
      start: {InferenceBroker, :start_link, [[name: InferenceBrokerTestInstanceUS3]]}
    })

    # Assert permissions on the parent directory
    assert File.exists?(tmp_dir)
    {:ok, stat} = File.stat(tmp_dir)
    perms = Bitwise.band(stat.mode, 0o777)
    assert perms == 0o700
  end

  test "US5: InferenceBroker refuses to start (fails secure) when GID cannot be applied" do
    tmp_dir = Path.join(System.tmp_dir!(), "inference_us5_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    tmp_socket = Path.join(tmp_dir, "inference.sock")

    orig_autostart = Application.get_env(:agent_os, :autostart)
    Application.put_env(:agent_os, :autostart, true)
    Application.put_env(:agent_os, :inference_uds_path, tmp_socket)

    # Configure an invalid GID that will cause :file.change_group/2 to return eperm
    Application.put_env(:agent_os, :inference_gid, 99999)

    on_exit(fn ->
      File.rm_rf(tmp_dir)

      if orig_autostart != nil,
        do: Application.put_env(:agent_os, :autostart, orig_autostart),
        else: Application.delete_env(:agent_os, :autostart)

      Application.delete_env(:agent_os, :inference_uds_path)
      Application.delete_env(:agent_os, :inference_gid)
    end)

    # start_supervised should return {:error, _} because start_uds_listener fails
    assert {:error, _} =
             start_supervised(%{
               id: InferenceBrokerTestInstanceUS5,
               start: {InferenceBroker, :start_link, [[name: InferenceBrokerTestInstanceUS5]]}
             })
  end

  test "T014 (a) gated synchronous tool use: complete recurses and handles web_search tool",
       context do
    # Configure manifest with web_search grant
    web_search_grant = %Manifest.Grant{
      connector: "web_search",
      recipients: nil,
      methods: ["search"]
    }

    manifest = %{
      context.manifest
      | grants: [web_search_grant],
        spend: %Spend{cap: 5000, window: :daily, on_breach: :kill}
    }

    # Reregister with the grant
    :ok = InferenceBroker.register(context.run_token, context.agent_name, manifest)

    req = %{
      run_token: context.run_token,
      model: "mock-model",
      messages: [%{role: "user", content: "who won the cup?"}]
    }

    # Set up mock handler for web_search
    Application.put_env(:agent_os, :web_search_mock_fn, fn query ->
      assert query == "elixir cup"
      {:ok, "Team Elixir won!"}
    end)

    on_exit(fn ->
      Application.delete_env(:agent_os, :web_search_mock_fn)
    end)

    # Provider fn returns a tool call on first call, then final text response on second call
    provider_fn = fn
      "mock-model", [%{role: "user"}], _tools, _secret ->
        %{
          input_tokens: 10,
          output_tokens: 10,
          completion: nil,
          message: %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_abc",
                "type" => "function",
                "function" => %{
                  "name" => "web_search",
                  "arguments" => "{\"query\": \"elixir cup\"}"
                }
              }
            ]
          }
        }

      "mock-model", messages, _tools, _secret ->
        # The history should contain the user prompt, assistant tool call, and tool result
        assert length(messages) == 3
        [_, assistant_msg, tool_msg] = messages
        assert assistant_msg["role"] == "assistant"
        assert tool_msg["role"] == "tool"
        assert tool_msg["content"] == "Team Elixir won!"

        %{
          input_tokens: 10,
          output_tokens: 10,
          completion: "Final response: Team Elixir won!"
        }
    end

    assert {:ok, %{completion: "Final response: Team Elixir won!"}} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn,
               prices: context.prices
             )
  end

  test "T014 (b) ungranted tool: returns error on ungranted tool call attempt", context do
    # No grants in manifest
    manifest = %{context.manifest | grants: []}
    :ok = InferenceBroker.register(context.run_token, context.agent_name, manifest)

    req = %{
      run_token: context.run_token,
      model: "mock-model",
      messages: [%{role: "user", content: "search web"}]
    }

    provider_fn = fn "mock-model", _messages, _tools, _secret ->
      %{
        input_tokens: 10,
        output_tokens: 10,
        completion: nil,
        message: %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "call_xyz",
              "type" => "function",
              "function" => %{
                "name" => "web_search",
                "arguments" => "{\"query\": \"secret\"}"
              }
            }
          ]
        }
      }
    end

    assert {:error, {:unauthorized_tool, "web_search"}} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn,
               prices: context.prices
             )
  end

  test "T014 (c) spend metering: tool cost is metered and spend cap limits apply", context do
    # Cost of web_search is 1000 micro-dollars (defined in metadata)
    web_search_grant = %Manifest.Grant{
      connector: "web_search",
      recipients: nil,
      methods: ["search"]
    }

    # Set cap to 1050. First LLM run costs 10*10 + 10*30 = 400.
    # Running web_search costs 1000. Total 1400 which exceeds cap.
    manifest = %{
      context.manifest
      | grants: [web_search_grant],
        spend: %Spend{cap: 1050, window: :daily, on_breach: :kill}
    }

    :ok = InferenceBroker.register(context.run_token, context.agent_name, manifest)

    req = %{
      run_token: context.run_token,
      model: "mock-model",
      messages: [%{role: "user", content: "search web"}]
    }

    provider_fn = fn "mock-model", _messages, _tools, _secret ->
      %{
        input_tokens: 10,
        output_tokens: 10,
        completion: nil,
        message: %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "call_xyz",
              "type" => "function",
              "function" => %{
                "name" => "web_search",
                "arguments" => "{\"query\": \"secret\"}"
              }
            }
          ]
        }
      }
    end

    assert {:breach, :spend} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn,
               prices: context.prices
             )
  end

  test "T014 (d) fault containment: caught exception or timeout in tool maps to error content string",
       context do
    web_search_grant = %Manifest.Grant{
      connector: "web_search",
      recipients: nil,
      methods: ["search"]
    }

    manifest = %{
      context.manifest
      | grants: [web_search_grant],
        spend: %Spend{cap: 5000, window: :daily, on_breach: :kill}
    }

    :ok = InferenceBroker.register(context.run_token, context.agent_name, manifest)

    req = %{
      run_token: context.run_token,
      model: "mock-model",
      messages: [%{role: "user", content: "crash search"}]
    }

    Application.put_env(:agent_os, :web_search_mock_fn, fn _query ->
      raise "WebSearch exploded!"
    end)

    on_exit(fn ->
      Application.delete_env(:agent_os, :web_search_mock_fn)
    end)

    provider_fn = fn
      "mock-model", [%{role: "user"}], _tools, _secret ->
        %{
          input_tokens: 10,
          output_tokens: 10,
          completion: nil,
          message: %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_xyz",
                "type" => "function",
                "function" => %{
                  "name" => "web_search",
                  "arguments" => "{\"query\": \"secret\"}"
                }
              }
            ]
          }
        }

      "mock-model", messages, _tools, _secret ->
        [_, _, tool_msg] = messages
        assert tool_msg["role"] == "tool"
        assert tool_msg["content"] =~ "exception" or tool_msg["content"] =~ "WebSearch exploded!"

        %{
          input_tokens: 10,
          output_tokens: 10,
          completion: "Handled error"
        }
    end

    assert {:ok, %{completion: "Handled error"}} =
             InferenceBroker.complete(req,
               now: context.now,
               provider_fn: provider_fn,
               prices: context.prices
             )
  end
end
