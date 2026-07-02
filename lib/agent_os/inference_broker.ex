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
  @spec register(String.t(), String.t(), AgentOS.Manifest.t()) :: :ok
  def register(token, agent_name, manifest) when is_binary(token) and is_binary(agent_name) do
    GenServer.call(__MODULE__, {:register, token, agent_name, manifest})
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
          {:ok, {String.t(), AgentOS.Manifest.t()}} | {:error, :unknown_run_token}
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
    model = Map.get(request, :model) || Map.get(request, "model")
    messages = Map.get(request, :messages) || Map.get(request, "messages")

    with {:ok, {agent_name, manifest}} <- resolve(token),
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
        Logger.error("Inference failed: unpriced model '#{inspect(model)}'")
        {:error, :unpriced_model}

      other ->
        Logger.error("Inference failed with unexpected error: #{inspect(other)}")
        {:error, other}
    end
  end

  # Helper to recursively call completions and execute tool requests
  defp do_complete_loop(
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

      provider_result =
        AgentOS.CredentialProxy.with_credential(:model_key, fn secret ->
          cond do
            is_function(provider_fn, 4) ->
              provider_fn.(model, messages, tools, secret)

            is_function(provider_fn, 3) ->
              provider_fn.(model, messages, secret)

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
              case execute_tool_calls(tool_calls, agent_name, manifest, opts) do
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

        _ ->
          acc
      end
    end)
  end

  # Iterates through tool calls and returns {:ok, tool_messages, accumulated_cost}
  defp execute_tool_calls(tool_calls, agent_name, manifest, _opts) do
    registry = AgentOS.Connector.registry()

    Enum.reduce_while(tool_calls, {:ok, [], 0}, fn tool_call, {:ok, msg_acc, cost_acc} ->
      tool_name = get_in(tool_call, ["function", "name"]) || get_in(tool_call, [:function, :name])
      tool_call_id = Map.get(tool_call, "id") || Map.get(tool_call, :id)

      args_str =
        get_in(tool_call, ["function", "arguments"]) || get_in(tool_call, [:function, :arguments])

      # Sandbox check: is the tool explicitly granted?
      is_granted? = Enum.any?(manifest.grants, fn g -> g.connector == tool_name end)

      if not is_granted? do
        Logger.error("Sandbox blocked ungranted tool: '#{tool_name}'")
        {:halt, {:error, {:unauthorized_tool, tool_name}}}
      else
        case Map.fetch(registry, tool_name) do
          {:ok, cap} ->
            tool_cost = Map.get(cap, :cost, 0)

            # Spend ledger lookup prior to tool call
            ledger = StateStore.snapshot("spend_ledger")
            raw_entry = Map.get(ledger, agent_name, %{spent: 0})
            current_spent = raw_entry.spent + cost_acc

            if current_spent + tool_cost >= manifest.spend.cap do
              Logger.warning("Spend cap exceeded before executing tool '#{tool_name}'")
              {:halt, {:breach, :spend}}
            else
              args =
                case Jason.decode(args_str) do
                  {:ok, decoded} -> decoded
                  {:error, _} -> %{}
                end

              {:ok, mod} = AgentOS.Connector.get_module(tool_name)
              credential_id = Map.get(cap, :credential)

              # Execute dynamic tool isolated and timeboxed
              tool_exec_result =
                if credential_id do
                  AgentOS.CredentialProxy.with_credential(credential_id, fn secret ->
                    execute_tool_isolated(mod, args, secret)
                  end)
                else
                  execute_tool_isolated(mod, args, nil)
                end

              case tool_exec_result do
                {:ok, res} ->
                  res_str = if is_binary(res), do: res, else: Jason.encode!(res)

                  msg = %{
                    "role" => "tool",
                    "tool_call_id" => tool_call_id,
                    "name" => tool_name,
                    "content" => res_str
                  }

                  {:cont, {:ok, msg_acc ++ [msg], cost_acc + tool_cost}}

                {:error, reason} ->
                  reason_str = "Error: " <> inspect(reason)

                  msg = %{
                    "role" => "tool",
                    "tool_call_id" => tool_call_id,
                    "name" => tool_name,
                    "content" => reason_str
                  }

                  {:cont, {:ok, msg_acc ++ [msg], cost_acc + tool_cost}}
              end
            end

          :error ->
            {:halt, {:error, {:unknown_connector, tool_name}}}
        end
      end
    end)
  end

  # Executes a tool connector inside a timeboxed, crash-isolated dynamic Task
  defp execute_tool_isolated(mod, arguments, secret) do
    # Fallback to local task supervisor if the global registry one is missing
    supervisor =
      case Process.whereis(AgentOS.ConnectorSupervisor) do
        nil ->
          {:ok, pid} = Task.Supervisor.start_link()
          pid

        pid ->
          pid
      end

    if function_exported?(mod, :execute_tool, 2) do
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          try do
            mod.execute_tool(arguments, secret)
          catch
            kind, reason ->
              {:error, {:exception, kind, reason}}
          end
        end)

      case Task.yield(task, 5000) || Task.shutdown(task) do
        {:ok, {:ok, res}} ->
          {:ok, res}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:ok, other} ->
          {:error, other}

        nil ->
          {:error, :timeout}
      end
    else
      {:error, :not_implemented}
    end
  end

  # Default/Real provider function using OpenRouter transport.
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

      case Req.post(url, json: body, headers: headers) do
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
      {:ok, body} ->
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

      _ ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp read_http_request(socket, buffer) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} ->
        new_buffer = buffer <> data

        case String.split(new_buffer, "\r\n\r\n", parts: 2) do
          [headers, body] ->
            case Regex.run(~r/[Cc]ontent-[Ll]ength:\s*(\d+)/, headers) do
              [_, length_str] ->
                content_length = String.to_integer(length_str)
                read_body(socket, body, content_length)

              _ ->
                {:ok, body}
            end

          _ ->
            read_http_request(socket, new_buffer)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_body(_socket, body, content_length) when byte_size(body) >= content_length do
    {:ok, binary_part(body, 0, content_length)}
  end

  defp read_body(socket, body, content_length) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} ->
        read_body(socket, body <> data, content_length)

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
  def handle_call({:register, token, agent_name, manifest}, _from, state) do
    new_tokens = Map.put(state.tokens, token, {agent_name, manifest})
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
