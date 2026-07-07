defmodule AgentOS.InferenceBroker do
  @moduledoc """
  Substrate-side inference chokepoint. Meters each model call into micro-dollars,
  enforces the spend cap per call, and is the sole holder of the inference credential key.

  The GenServer process maintains the mapping of per-run tokens to agent metadata
  and manifests. The core call evaluation is performed in the caller's process to
  prevent network or API latency from blocking token resolution.
  """

  use GenServer
  require Logger

  alias AgentOS.StateStore
  alias AgentOS.InferencePrice

  @type request :: %{
          run_token: String.t(),
          model: String.t(),
          messages: [map()]
        }

  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          completion: term()
        }

  @type result ::
          {:ok, %{completion: term()}}
          | {:breach, :spend}
          | {:error,
             :unpriced_model
             | :unknown_run_token
             | :missing_usage
             | :timeout
             | :network_error
             | {:http_status, integer()}}

  # --- Client API ---

  @doc """
  Starts the InferenceBroker GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Registers a per-run token to its corresponding agent name and manifest.
  """
  @spec register(String.t(), String.t(), AgentOS.Manifest.t(), :live | :record, String.t() | nil) ::
          :ok
  def register(token, agent_name, manifest, mode \\ :live, effective_model \\ nil)
      when is_binary(token) and is_binary(agent_name) do
    GenServer.call(__MODULE__, {:register, token, agent_name, manifest, mode, effective_model})
  end

  @doc """
  Unregisters a per-run token.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(token) when is_binary(token) do
    GenServer.call(__MODULE__, {:unregister, token})
  end

  @doc """
  Resolves a per-run token to its agent name and manifest.
  """
  @spec resolve(String.t()) ::
          {:ok, map()} | {:error, :unknown_run_token}
  def resolve(token) when is_binary(token) do
    GenServer.call(__MODULE__, {:resolve, token})
  end

  @doc """
  Executes an inference request. Resolves the run token, verifies the model pricing,
  performs pre-check and post-meter check against the agent's spend cap, and
  calls the provider.

  ## Options
    - `:now` - The current time (useful for deterministic tests). Defaults to UTC now.
    - `:provider_fn` - The provider call function. Mocked in tests, defaults to real client.
    - `:prices` - The per-model price table. Defaults to config prices.
  """
  @spec complete(request(), opts :: keyword()) :: result()
  def complete(request, opts \\ []) do
    token = Map.get(request, :run_token) || Map.get(request, "run_token")
    requested_model = Map.get(request, :model) || Map.get(request, "model")
    messages = Map.get(request, :messages) || Map.get(request, "messages")

    with {:ok, resolved} <- resolve(token),
         model = resolved.effective_model || requested_model,
         agent_name = resolved.agent_name,
         manifest = resolved.manifest,
         prices =
           Keyword.get(opts, :prices) || Application.get_env(:agent_os, :inference_prices, %{}),
         {:ok, price_entry} <- InferencePrice.lookup(prices, model) do
      now = Keyword.get(opts, :now) || DateTime.utc_now()

      # Read the agent's spend_ledger entry
      spend_ledger = StateStore.snapshot("spend_ledger")
      raw_entry = Map.get(spend_ledger, agent_name, %{spent: 0, window_start: now})

      # Normalise window reset
      agent_entry = AgentOS.SpendLedger.current_entry(raw_entry, now, manifest.spend.window)

      if agent_entry != raw_entry do
        StateStore.apply_action("spend_ledger", {:put, agent_name, agent_entry})
      end

      # Filter active tools based on manifest grants
      tools = build_tools_list(manifest)

      default_provider =
        if length(tools) > 0 do
          &real_provider_fn/4
        else
          &real_provider_fn/3
        end

      provider_fn =
        Keyword.get(opts, :provider_fn) || Application.get_env(:agent_os, :provider_fn) ||
          default_provider

      do_complete_loop(
        token,
        messages,
        agent_entry.spent,
        agent_name,
        manifest,
        model,
        prices,
        price_entry,
        provider_fn,
        opts
      )
    else
      {:error, :unknown_run_token} ->
        Logger.error("Inference failed: unknown run token '#{inspect(token)}'")
        {:error, :unknown_run_token}

      {:error, :unpriced_model} ->
        Logger.error(
          "Inference failed: unpriced model (requested: '#{inspect(requested_model)}')"
        )

        {:error, :unpriced_model}

      other ->
        Logger.error("Inference failed with unexpected error: #{inspect(other)}")
        {:error, other}
    end
  end

  @doc """
  Direct tool-submission channel: runs an agent's submitted tool calls through the
  SAME deterministic gate as the inference path (`CapabilityRail.evaluate_tool_calls/4`)
  with **no model call anywhere**. Identical gating/parking/recording semantics; the
  rail remains the sole transcript writer.

  Resolves the run token → normalizes the spend window → pre-checks the cap →
  evaluates the calls → persists accumulated connector cost to the spend ledger →
  returns typed per-call results. Zero inference charges by construction.

  Returns:
    - `{:ok, %{results: [%{id, name, disposition, content}]}}` where
      `disposition ∈ "executed" | "error" | "rejected" | "parked"`
      ("error" = granted but the connector's execution failed)
    - `{:breach, :spend}` when the cap is already reached or would be crossed
    - `{:error, :bad_request}` for a malformed submission
    - `{:error, :unknown_run_token}` for an unregistered token
  """
  @spec submit_tool_calls(map(), keyword()) ::
          {:ok, %{results: [map()]}}
          | {:breach, :spend}
          | {:error, :bad_request | :unknown_run_token}
  def submit_tool_calls(request, opts \\ []) do
    with {:ok, submission} <- AgentOS.ToolSubmission.from_map(request),
         {:ok, resolved} <- resolve(submission.run_token) do
      do_submit_tool_calls(submission, resolved, opts)
    else
      {:error, :bad_request} ->
        Logger.error("Tool submission rejected: malformed request (not a valid tool submission)")
        {:error, :bad_request}

      {:error, :unknown_run_token} ->
        Logger.error("Tool submission rejected: unknown run token")
        {:error, :unknown_run_token}
    end
  end

  defp do_submit_tool_calls(submission, resolved, opts) do
    %AgentOS.ToolSubmission{run_token: run_token, tool_calls: tool_calls} = submission
    agent_name = resolved.agent_name
    manifest = resolved.manifest
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    # Normalise the spend window exactly as the inference path does, then pre-check
    # the cap so an already-exhausted agent never reaches the rail.
    spend_ledger = StateStore.snapshot("spend_ledger")
    raw_entry = Map.get(spend_ledger, agent_name, %{spent: 0, window_start: now})
    agent_entry = AgentOS.SpendLedger.current_entry(raw_entry, now, manifest.spend.window)

    if agent_entry != raw_entry do
      StateStore.apply_action("spend_ledger", {:put, agent_name, agent_entry})
    end

    if agent_entry.spent >= manifest.spend.cap do
      Logger.warning(
        "Tool submission blocked: agent '#{agent_name}' spent (#{to_dollars(agent_entry.spent)}) >= cap (#{to_dollars(manifest.spend.cap)})"
      )

      {:breach, :spend}
    else
      # Snapshot the transcript length so we can read exactly the dispositions this
      # submission produced (the rail appends one entry per call, in order).
      entries_before = length(AgentOS.ActionTranscript.read(run_token).entries)

      case AgentOS.CapabilityRail.evaluate_tool_calls(tool_calls, agent_name, manifest, run_token) do
        {:ok, tool_messages, tool_cost} ->
          persist_tool_cost(agent_name, agent_entry.spent, tool_cost, now)

          new_entries =
            Enum.drop(AgentOS.ActionTranscript.read(run_token).entries, entries_before)

          {:ok, %{results: build_results(tool_messages, new_entries)}}

        {:breach, :spend} ->
          {:breach, :spend}
      end
    end
  end

  # Persists accumulated connector cost through the same {:put, agent_name, entry}
  # action the inference path uses — connector costs are real spend (FR-012).
  defp persist_tool_cost(_agent_name, _spent, 0, _now), do: :ok

  defp persist_tool_cost(agent_name, spent, tool_cost, now) do
    StateStore.apply_action(
      "spend_ledger",
      {:put, agent_name, %{spent: spent + tool_cost, window_start: now}}
    )
  end

  # Zips the rail's per-call tool messages (id/name/content — the SAME feedback string
  # the inference path returns) with the transcript entries the rail just appended
  # (disposition kind), producing the typed channel response. No new transcript writer.
  defp build_results(tool_messages, entries) do
    tool_messages
    |> Enum.zip(entries)
    |> Enum.map(fn {msg, entry} ->
      %{
        id: Map.get(msg, "tool_call_id"),
        name: Map.get(msg, "name"),
        disposition: disposition_of(entry),
        content: Map.get(msg, "content")
      }
    end)
  end

  # A granted call whose connector raised/failed is recorded :granted with an error
  # result — surface it as "error" so a deterministic body can report honestly
  # instead of mistaking a failed effect for success.
  defp disposition_of(%{kind: :granted, result: %{"error" => _}}), do: "error"
  defp disposition_of(%{kind: :granted}), do: "executed"
  defp disposition_of(%{kind: :rejected}), do: "rejected"
  defp disposition_of(%{kind: :parked}), do: "parked"

  # Helper to recursively call completions and execute tool requests
  defp do_complete_loop(
         run_token,
         messages,
         spent,
         agent_name,
         manifest,
         model,
         prices,
         price_entry,
         provider_fn,
         opts
       ) do
    if spent >= manifest.spend.cap do
      Logger.warning(
        "Inference blocked: agent '#{agent_name}' spent (#{to_dollars(spent)}) >= cap (#{to_dollars(manifest.spend.cap)})"
      )

      {:breach, :spend}
    else
      tools = build_tools_list(manifest)

      capabilities_context = """
      [OS CONTEXT INJECTED BY INFERENCE BROKER]
      You are an AgentOS autonomous agent.
      Your runtime capabilities are strictly limited to the following:
      #{AgentOS.CapabilityRender.render(manifest)}
      """

      system_msg = %{
        role: "system",
        content: capabilities_context
      }

      injected_messages = [system_msg | messages]

      provider_result =
        AgentOS.CredentialProxy.with_credential(:model_key, fn secret ->
          cond do
            is_function(provider_fn, 4) ->
              provider_fn.(model, injected_messages, tools, secret)

            is_function(provider_fn, 3) ->
              provider_fn.(model, injected_messages, secret)

            true ->
              raise ArgumentError, "provider_fn must have arity 3 or 4"
          end
        end)

      case provider_result do
        %{input_tokens: _, output_tokens: _, completion: _} = usage ->
          dollars = InferencePrice.micro_dollars(usage, price_entry)
          new_spent = spent + dollars

          # Persist LLM run cost
          updated_entry = %{
            spent: new_spent,
            window_start: Keyword.get(opts, :now) || DateTime.utc_now()
          }

          StateStore.apply_action("spend_ledger", {:put, agent_name, updated_entry})

          if new_spent >= manifest.spend.cap do
            Logger.warning(
              "Inference breach: agent '#{agent_name}' spent (#{to_dollars(new_spent)}) crossed cap (#{to_dollars(manifest.spend.cap)})"
            )

            {:breach, :spend}
          else
            message =
              Map.get(usage, :message) || %{"role" => "assistant", "content" => usage.completion}

            tool_calls = Map.get(message, "tool_calls") || Map.get(message, :tool_calls)

            if is_list(tool_calls) and length(tool_calls) > 0 do
              # Append assistant tool invocation message to conversation history
              assistant_msg = %{
                "role" => "assistant",
                "content" => Map.get(message, "content"),
                "tool_calls" => tool_calls
              }

              updated_messages = messages ++ [assistant_msg]

              # Execute all requested tool calls in order
              case AgentOS.CapabilityRail.evaluate_tool_calls(
                     tool_calls,
                     agent_name,
                     manifest,
                     run_token
                   ) do
                {:ok, tool_messages, tool_cost} ->
                  final_spent = new_spent + tool_cost

                  if final_spent >= manifest.spend.cap do
                    Logger.warning(
                      "Inference breach after tool execution: agent '#{agent_name}' spent (#{to_dollars(final_spent)}) crossed cap (#{to_dollars(manifest.spend.cap)})"
                    )

                    {:breach, :spend}
                  else
                    # Persist accumulated tool cost
                    tool_updated_entry = %{
                      spent: final_spent,
                      window_start: Keyword.get(opts, :now) || DateTime.utc_now()
                    }

                    StateStore.apply_action(
                      "spend_ledger",
                      {:put, agent_name, tool_updated_entry}
                    )

                    # Recurse completions with updated message history
                    do_complete_loop(
                      run_token,
                      updated_messages ++ tool_messages,
                      final_spent,
                      agent_name,
                      manifest,
                      model,
                      prices,
                      price_entry,
                      provider_fn,
                      opts
                    )
                  end

                {:error, reason} ->
                  {:error, reason}

                {:breach, :spend} ->
                  {:breach, :spend}
              end
            else
              {:ok, %{completion: usage.completion}}
            end
          end

        {:error, reason} ->
          Logger.error("Inference failed: #{inspect(reason)}")
          {:error, reason}

        _ ->
          Logger.error("Inference failed: provider response missing usage information")
          {:error, :missing_usage}
      end
    end
  end

  # Filters connectors granted in manifest and extracts their tool declarations
  defp build_tools_list(manifest) do
    registry = AgentOS.Connector.registry()

    Enum.reduce(manifest.grants, [], fn grant, acc ->
      case Map.fetch(registry, grant.connector) do
        {:ok, %{tool_declaration: declaration}} when not is_nil(declaration) ->
          acc ++ [declaration]

        {:ok, _cap} ->
          raise ArgumentError,
                "Granted connector '#{grant.connector}' is missing a tool_declaration."

        :error ->
          # If the connector is entirely missing from registry, just skip or raise. 
          # For defense in depth against bad manifests, raise.
          raise ArgumentError,
                "Granted connector '#{grant.connector}' is unknown."
      end
    end)
  end

  defp real_provider_fn(model, messages, secret) do
    real_provider_fn(model, messages, [], secret)
  end

  defp real_provider_fn(model, messages, tools, secret) do
    if is_nil(secret) or String.trim(secret) == "" do
      Logger.error("Inference failed: model API key is missing or blank")
      {:error, :missing_credential}
    else
      url = "https://openrouter.ai/api/v1/chat/completions"

      headers = [
        {"authorization", "Bearer #{secret}"},
        {"content-type", "application/json"}
      ]

      body =
        if is_list(tools) and length(tools) > 0 do
          %{
            "model" => model,
            "messages" => messages,
            "tools" => tools
          }
        else
          %{
            "model" => model,
            "messages" => messages
          }
        end

      case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
        {:ok, %Req.Response{status: 200, body: response_body}} ->
          case parse_openrouter_response(response_body) do
            {:ok, usage_data} ->
              usage_data

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, %Req.Response{status: status}} ->
          Logger.error("OpenRouter API returned error status: #{status}")
          {:error, {:http_status, status}}

        {:error, %{reason: :timeout}} ->
          Logger.error("OpenRouter API request timeout")
          {:error, :timeout}

        {:error, reason} ->
          Logger.error("OpenRouter API request failed: #{inspect(reason)}")
          {:error, :network_error}
      end
    end
  end

  defp parse_openrouter_response(body) when is_map(body) do
    with [_ | _] = choices <- Map.get(body, "choices"),
         %{"message" => message} <- List.first(choices),
         %{"prompt_tokens" => input_tokens, "completion_tokens" => output_tokens} <-
           Map.get(body, "usage") do
      {:ok,
       %{
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         completion: Map.get(message, "content"),
         message: message
       }}
    else
      _ ->
        Logger.error("Failed to parse OpenRouter response: #{inspect(body)}")
        {:error, :missing_usage}
    end
  end

  defp parse_openrouter_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_openrouter_response(decoded)
      {:error, _} -> {:error, :missing_usage}
    end
  end

  defp parse_openrouter_response(_body) do
    {:error, :missing_usage}
  end

  @doc """
  Gets the configured dedicated inference GID.
  Defaults to the current process's primary GID if not configured.
  """
  @spec get_configured_gid() :: integer()
  def get_configured_gid do
    raw_gid = System.get_env("INFERENCE_GID") || Application.get_env(:agent_os, :inference_gid)

    case raw_gid do
      nil ->
        get_default_gid()

      num when is_integer(num) ->
        num

      str when is_binary(str) ->
        case Integer.parse(str) do
          {num, ""} ->
            num

          _ ->
            Logger.warning(
              "Invalid GID configuration, falling back to default GID: #{inspect(str)}"
            )

            get_default_gid()
        end
    end
  end

  defp get_default_gid do
    case System.cmd("id", ["-g"]) do
      {gid_str, 0} ->
        String.trim(gid_str) |> String.to_integer()

      _ ->
        1000
    end
  end

  # --- UDS Listener ---

  defp start_uds_listener(socket_path) do
    File.rm(socket_path)
    parent_dir = Path.dirname(socket_path)
    File.mkdir_p!(parent_dir)

    with :ok <- File.chmod(parent_dir, 0o700),
         {:ok, listen_socket} <-
           :gen_tcp.listen(0, [
             :binary,
             packet: :raw,
             active: false,
             reuseaddr: true,
             ifaddr: {:local, socket_path}
           ]) do
      case File.chmod(socket_path, 0o660) do
        :ok ->
          target_gid = get_configured_gid()

          case :file.change_group(String.to_charlist(socket_path), target_gid) do
            :ok ->
              Logger.info(
                "InferenceBroker UDS listener started at #{socket_path} (mode: 0660, group: #{target_gid})"
              )

              Task.start_link(fn -> accept_loop(listen_socket) end)
              {:ok, listen_socket}

            {:error, reason} ->
              Logger.error(
                "Failed to change group of socket #{socket_path} to GID #{target_gid}: #{inspect(reason)}"
              )

              :gen_tcp.close(listen_socket)
              File.rm(socket_path)
              {:error, {:change_group_failed, reason}}
          end

        {:error, reason} ->
          Logger.error(
            "Failed to set 0660 permissions on socket #{socket_path}: #{inspect(reason)}"
          )

          :gen_tcp.close(listen_socket)
          File.rm(socket_path)
          {:error, {:chmod_failed, reason}}
      end
    else
      {:error, reason} ->
        Logger.error("Failed to start InferenceBroker UDS listener: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        Task.start(fn -> handle_connection(socket) end)
        accept_loop(listen_socket)

      {:error, reason} ->
        Logger.error("Accept error: #{inspect(reason)}")
    end
  end

  defp handle_connection(socket) do
    case read_http_request(socket, "") do
      {:ok, path, body} ->
        route_request(socket, path, body)

      _ ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  # Routes by request path. `/v1/tool_calls` runs the direct tool-submission channel
  # (no model); ANY other path (including `/v1/inference` and legacy pathless requests)
  # keeps today's inference behaviour, so deployed agents are untouched.
  defp route_request(socket, "/v1/tool_calls", body) do
    case Jason.decode(body) do
      {:ok, request_map} ->
        case submit_tool_calls(request_map) do
          {:ok, %{results: results}} ->
            send_json_response(socket, 200, %{results: results})

          {:breach, :spend} ->
            send_json_response(socket, 402, %{error: :spend_breach})

          {:error, :unknown_run_token} ->
            send_json_response(socket, 401, %{error: :unknown_run_token})

          {:error, :bad_request} ->
            send_json_response(socket, 400, %{error: :bad_request})
        end

      _ ->
        send_json_response(socket, 400, %{error: :bad_request})
    end
  end

  defp route_request(socket, _path, body) do
    case Jason.decode(body) do
      {:ok, request_map} ->
        case complete(request_map) do
          {:ok, %{completion: comp}} ->
            send_json_response(socket, 200, %{completion: comp})

          {:breach, :spend} ->
            send_json_response(socket, 402, %{error: :spend_breach})

          {:error, :unpriced_model} ->
            send_json_response(socket, 400, %{error: :unpriced_model})

          {:error, :unknown_run_token} ->
            send_json_response(socket, 401, %{error: :unknown_run_token})

          {:error, other} ->
            send_json_response(socket, 400, %{error: inspect(other)})
        end

      _ ->
        send_json_response(socket, 400, %{error: :bad_request})
    end
  end

  defp read_http_request(socket, buffer) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} ->
        new_buffer = buffer <> data

        case String.split(new_buffer, "\r\n\r\n", parts: 2) do
          [headers, body] ->
            path = parse_request_path(headers)

            case Regex.run(~r/[Cc]ontent-[Ll]ength:\s*(\d+)/, headers) do
              [_, length_str] ->
                content_length = String.to_integer(length_str)
                read_body(socket, path, body, content_length)

              _ ->
                {:ok, path, body}
            end

          _ ->
            read_http_request(socket, new_buffer)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Extracts the request-target path from the HTTP request line ("METHOD path VERSION").
  # Returns nil when the request line is absent/unparseable, in which case routing
  # falls through to the default inference behaviour.
  defp parse_request_path(headers) do
    with request_line <- headers |> String.split("\r\n") |> List.first(),
         true <- is_binary(request_line),
         [_method, path | _] <- String.split(request_line, " ") do
      path
    else
      _ -> nil
    end
  end

  defp read_body(_socket, path, body, content_length) when byte_size(body) >= content_length do
    {:ok, path, binary_part(body, 0, content_length)}
  end

  defp read_body(socket, path, body, content_length) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} ->
        read_body(socket, path, body <> data, content_length)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_json_response(socket, status, payload) do
    body = Jason.encode!(payload)

    status_msg =
      case status do
        200 -> "200 OK"
        400 -> "400 Bad Request"
        401 -> "401 Unauthorized"
        402 -> "402 Payment Required"
        _ -> "500 Internal Server Error"
      end

    resp =
      "HTTP/1.1 #{status_msg}\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <>
        body

    :gen_tcp.send(socket, resp)
  end

  # --- Server Callbacks ---

  @impl true
  def init(:ok) do
    if Application.get_env(:agent_os, :autostart, true) do
      socket_path = Application.get_env(:agent_os, :inference_uds_path, "data/inference.sock")

      case start_uds_listener(socket_path) do
        {:ok, listen_socket} ->
          {:ok, %{listen_socket: listen_socket, tokens: %{}}}

        {:error, reason} ->
          {:stop, {:uds_listener_failed, reason}}
      end
    else
      {:ok, %{tokens: %{}}}
    end
  end

  @impl true
  def handle_call({:register, token, agent_name, manifest, mode, effective_model}, _from, state) do
    entry = %{
      agent_name: agent_name,
      manifest: manifest,
      mode: mode,
      effective_model: effective_model
    }

    new_tokens = Map.put(state.tokens, token, entry)
    {:reply, :ok, Map.put(state, :tokens, new_tokens)}
  end

  @impl true
  def handle_call({:unregister, token}, _from, state) do
    new_tokens = Map.delete(state.tokens, token)
    {:reply, :ok, Map.put(state, :tokens, new_tokens)}
  end

  @impl true
  def handle_call({:resolve, token}, _from, state) do
    case Map.fetch(state.tokens, token) do
      {:ok, val} -> {:reply, {:ok, val}, state}
      :error -> {:reply, {:error, :unknown_run_token}, state}
    end
  end

  defp to_dollars(microdollars) do
    "$" <> :erlang.float_to_binary(microdollars / 1_000_000, [{:decimals, 6}, :compact])
  end
end
