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

      # Pre-check
      if agent_entry.spent >= manifest.spend.cap do
        Logger.warning(
          "Inference blocked: agent '#{agent_name}' spent (#{agent_entry.spent}) >= cap (#{manifest.spend.cap})"
        )

        {:breach, :spend}
      else
        provider_fn = Keyword.get(opts, :provider_fn) || (&real_provider_fn/3)

        # Call provider via CredentialProxy
        provider_result =
          AgentOS.CredentialProxy.with_credential(:model_key, fn secret ->
            provider_fn.(model, messages, secret)
          end)

        case provider_result do
          %{input_tokens: _, output_tokens: _, completion: comp} = usage ->
            # Compute dollars in micro-dollars
            dollars = InferencePrice.micro_dollars(usage, price_entry)

            # Persist spent + dollars
            new_spent = agent_entry.spent + dollars
            updated_entry = Map.put(agent_entry, :spent, new_spent)
            StateStore.apply_action("spend_ledger", {:put, agent_name, updated_entry})

            # Post-meter check
            if new_spent >= manifest.spend.cap do
              Logger.warning(
                "Inference breach: agent '#{agent_name}' spent (#{new_spent}) crossed cap (#{manifest.spend.cap})"
              )

              {:breach, :spend}
            else
              {:ok, %{completion: comp}}
            end

          {:error, reason} ->
            Logger.error("Inference failed: #{inspect(reason)}")
            {:error, reason}

          _ ->
            Logger.error("Inference failed: provider response missing usage information")
            {:error, :missing_usage}
        end
      end
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

  # Default/Real provider function using OpenRouter transport.
  defp real_provider_fn(model, messages, secret) do
    url = "https://openrouter.ai/api/v1/chat/completions"

    headers = [
      {"authorization", "Bearer #{secret}"},
      {"content-type", "application/json"}
    ]

    body = %{
      "model" => model,
      "messages" => messages
    }

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

  defp parse_openrouter_response(body) when is_map(body) do
    with [_ | _] = choices <- Map.get(body, "choices"),
         %{"message" => %{"content" => completion}} <- List.first(choices),
         %{"prompt_tokens" => input_tokens, "completion_tokens" => output_tokens} <-
           Map.get(body, "usage") do
      {:ok,
       %{
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         completion: completion
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

  # --- UDS Listener ---

  defp start_uds_listener(socket_path) do
    File.rm(socket_path)
    Path.dirname(socket_path) |> File.mkdir_p!()

    case :gen_tcp.listen(0, [
           :binary,
           packet: :raw,
           active: false,
           reuseaddr: true,
           ifaddr: {:local, socket_path}
         ]) do
      {:ok, listen_socket} ->
        Logger.info("InferenceBroker UDS listener started at #{socket_path}")
        Task.start_link(fn -> accept_loop(listen_socket) end)
        {:ok, listen_socket}

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
                send_json_response(socket, 400, %{error: other})
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

        {:error, _reason} ->
          {:ok, %{tokens: %{}}}
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
end
