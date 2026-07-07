# Exclude container/docker tests by default to keep the local suite hermetic.
# Run them explicitly via: mix test --include docker
System.put_env("SEARCH_API_KEY", "test_search_api_key_value")

# Constitution IV guard: no test may reach the live Discord webhook. The credential
# resolver falls back to System env (a developer shell may export the REAL
# DISCORD_WEBHOOK_URL), so a suite-wide safe transport stub is installed here.
# Tests asserting transport behavior override it per-test with put_env — never
# delete_env, which would drop this guard for concurrently running tests.
Application.put_env(:agent_os, :discord_notify_transport, fn _url, _opts ->
  {:ok, %Req.Response{status: 204}}
end)

ExUnit.start(exclude: [:docker])

defmodule AgentOS.TestHelper do
  def start_mounts!(initial_spend \\ %{}, initial_approvals \\ %{approvals: %{}}) do
    uniq = System.unique_integer([:positive])
    tmp_dir = System.tmp_dir!()

    roster_path = Path.join(tmp_dir, "roster_#{uniq}.db")
    spend_path = Path.join(tmp_dir, "spend_#{uniq}.db")
    approvals_path = Path.join(tmp_dir, "approvals_#{uniq}.db")
    admitted_plugins_path = Path.join(tmp_dir, "admitted_plugins_#{uniq}.db")
    conformance_path = Path.join(tmp_dir, "conformance_#{uniq}.db")
    provenance_path = Path.join(tmp_dir, "provenance_#{uniq}.db")
    judge_path = Path.join(tmp_dir, "judge_#{uniq}.db")
    review_path = Path.join(tmp_dir, "review_#{uniq}.db")

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(roster_path)
      File.rm(spend_path)
      File.rm(approvals_path)
      File.rm(admitted_plugins_path)
      File.rm(conformance_path)
      File.rm(provenance_path)

      try do
        File.rm(judge_path)
      rescue
        _ -> :ok
      end

      try do
        File.rm(review_path)
      rescue
        _ -> :ok
      end
    end)

    if Process.whereis(AgentOS.StateStoreRegistry) == nil do
      ExUnit.Callbacks.start_supervised!(
        {Registry, keys: :unique, name: AgentOS.StateStoreRegistry}
      )
    end

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "roster_trust", path: roster_path, initial: %{records: []}}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "spend_ledger", path: spend_path, initial: initial_spend}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore,
       name: "pending_approvals", path: approvals_path, initial: initial_approvals}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "admitted_plugins", path: admitted_plugins_path, initial: %{}}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "conformance", path: conformance_path, initial: %{}}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "provenance", path: provenance_path, initial: %{}}
    )

    action_transcript_path = Path.join(tmp_dir, "action_transcript_#{uniq}.db")
    ExUnit.Callbacks.on_exit(fn -> File.rm(action_transcript_path) end)

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "action_transcript", path: action_transcript_path, initial: %{}}
    )

    default_pass = %{status: :pass, code_hash: ""}

    default_review_pass = %AgentOS.Pipeline.Stage5.Verdict{
      status: :pass,
      reasoning: "ok",
      timestamp: DateTime.utc_now(),
      code_hash: ""
    }

    initial_judge = %{
      "discovery" => default_pass,
      "spend_agent" => default_pass,
      "restart_agent" => default_pass,
      "alert_agent" => default_pass,
      "roster_agent" => default_pass,
      "mixed_agent" => default_pass,
      "conformance_agent" => default_pass,
      "drift_agent" => default_pass,
      "test_agent" => default_pass
    }

    initial_review = %{
      "discovery" => default_review_pass,
      "spend_agent" => default_review_pass,
      "restart_agent" => default_review_pass,
      "alert_agent" => default_review_pass,
      "roster_agent" => default_review_pass,
      "mixed_agent" => default_review_pass,
      "conformance_agent" => default_review_pass,
      "drift_agent" => default_review_pass,
      "test_agent" => default_review_pass
    }

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore, name: "judge_results", path: judge_path, initial: initial_judge}
    )

    ExUnit.Callbacks.start_supervised!(
      {AgentOS.StateStore,
       name: "security_review_results", path: review_path, initial: initial_review}
    )

    %{
      roster_path: roster_path,
      spend_ledger_path: spend_path,
      pending_approvals_path: approvals_path,
      conformance_path: conformance_path,
      provenance_path: provenance_path,
      judge_path: judge_path,
      review_path: review_path
    }
  end

  @doc """
  Starts a real InferenceBroker with its UDS listener and a stubbed provider_fn, so a
  port agent (e.g. agents/discovery/main.py) can drive the tool-call channel end to end
  without any live model. Returns the socket path. Restores config on exit.
  """
  def start_broker_uds!(provider_fn) do
    uniq = System.unique_integer([:positive])
    # The broker chmods the socket's PARENT dir to 0700, so it must be a dir we own
    # (not /tmp itself). Keep the path short to stay under the ~104-char UDS limit.
    sock_dir = "/tmp/aos_inf_#{uniq}"
    File.mkdir_p!(sock_dir)
    sock = Path.join(sock_dir, "inf.sock")

    prev_uds = Application.get_env(:agent_os, :inference_uds_path)
    prev_autostart = Application.get_env(:agent_os, :autostart)
    prev_provider = Application.get_env(:agent_os, :provider_fn)

    Application.put_env(:agent_os, :inference_uds_path, sock)
    Application.put_env(:agent_os, :autostart, true)
    Application.put_env(:agent_os, :provider_fn, provider_fn)

    ExUnit.Callbacks.on_exit(fn ->
      if prev_uds,
        do: Application.put_env(:agent_os, :inference_uds_path, prev_uds),
        else: Application.delete_env(:agent_os, :inference_uds_path)

      Application.put_env(:agent_os, :autostart, prev_autostart)

      if prev_provider,
        do: Application.put_env(:agent_os, :provider_fn, prev_provider),
        else: Application.delete_env(:agent_os, :provider_fn)

      File.rm(sock)
      File.rm_rf(sock_dir)
    end)

    if Process.whereis(AgentOS.CredentialProxy) == nil do
      ExUnit.Callbacks.start_supervised!(AgentOS.CredentialProxy)
    end

    ExUnit.Callbacks.start_supervised!(AgentOS.InferenceBroker)
    sock
  end

  @doc """
  Posts a tool submission to the broker's `/v1/tool_calls` route over the UDS,
  mirroring the HTTP-over-UDS framing an agent process uses. Returns
  `{status_code, decoded_json_body}`. Used by the channel tests to exercise routing
  without a Python container.
  """
  def submit_tool_calls_uds(sock_path, %{} = payload) do
    body = Jason.encode!(payload)

    request =
      "POST /v1/tool_calls HTTP/1.1\r\n" <>
        "Host: localhost\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <> body

    {:ok, socket} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(socket, request)
    response = recv_all(socket, "")
    :gen_tcp.close(socket)

    [headers, resp_body] = String.split(response, "\r\n\r\n", parts: 2)
    status = headers |> String.split(" ") |> Enum.at(1) |> String.to_integer()
    {status, Jason.decode!(resp_body)}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, _} -> acc
    end
  end

  @doc """
  Asserts that an agent's spend ledger reflects ONLY metered connector cost and no
  inference charge — the direct-channel invariant that a no-LLM run's spend equals
  the sum of executed connector costs exactly (default 0 when no connector executed).
  """
  def refute_inference_spend(agent_name, connector_cost \\ 0) do
    ledger = AgentOS.StateStore.snapshot("spend_ledger")

    spent =
      case Map.get(ledger, agent_name) do
        nil -> 0
        %{spent: s} -> s
      end

    if spent != connector_cost do
      raise ExUnit.AssertionError,
        message:
          "expected spend for #{agent_name} to equal connector cost #{connector_cost} " <>
            "(zero inference charge), got #{spent}"
    end

    :ok
  end

  @high_signal ~w(high valid signal breakthrough alice) ++ ["plain string"]
  @adversarial ["ignore earlier instructions", "prompt injection"]

  @doc """
  Deterministic stand-in for the discovery agent's model. Reads the items from the
  user message and emits kv_append tool calls for high-signal, non-adversarial items —
  the same reasoning the retired build_actions/0 encoded. Terminates the tool loop by
  returning a plain completion once tool results are present.
  """
  def discovery_provider_fn do
    fn _model, messages, _tools, _secret ->
      already_ran? =
        Enum.any?(messages, fn m -> (Map.get(m, "role") || Map.get(m, :role)) == "tool" end)

      if already_ran? do
        %{
          input_tokens: 5,
          output_tokens: 5,
          completion: "done",
          message: %{"role" => "assistant", "content" => "done"}
        }
      else
        tool_calls = messages |> extract_items() |> build_kv_tool_calls()

        %{
          input_tokens: 10,
          output_tokens: 10,
          completion: nil,
          message: %{"role" => "assistant", "content" => nil, "tool_calls" => tool_calls}
        }
      end
    end
  end

  defp extract_items(messages) do
    user =
      Enum.find(messages, fn m -> (Map.get(m, "role") || Map.get(m, :role)) == "user" end)

    content = if user, do: Map.get(user, "content") || Map.get(user, :content), else: nil

    with true <- is_binary(content),
         {:ok, %{"items" => items}} <- Jason.decode(content) do
      items
    else
      _ -> []
    end
  end

  defp build_kv_tool_calls(items) do
    kept =
      items
      |> Enum.map(fn item -> Map.get(item, "text", "") end)
      |> Enum.reject(&adversarial?/1)
      |> Enum.filter(&high_signal?/1)

    case kept do
      [] ->
        [kv_tool_call(0, "no high-signal input")]

      texts ->
        texts
        |> Enum.with_index()
        |> Enum.map(fn {text, i} -> kv_tool_call(i, "high-signal: #{text}") end)
    end
  end

  defp adversarial?(text) do
    lower = String.downcase(text)
    Enum.any?(@adversarial, &String.contains?(lower, &1))
  end

  defp high_signal?(text) do
    lower = String.downcase(text)
    Enum.any?(@high_signal, &String.contains?(lower, &1))
  end

  defp kv_tool_call(i, value) do
    %{
      "id" => "call_#{i}",
      "type" => "function",
      "function" => %{
        "name" => "kv_append",
        "arguments" => Jason.encode!(%{"value" => value, "method" => "append"})
      }
    }
  end
end
