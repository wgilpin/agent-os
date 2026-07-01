defmodule AgentOS.InferencePriceSync do
  @moduledoc """
  GenServer that synchronises model pricing dynamically from OpenRouter.
  It fetches the public pricing catalog at startup and periodically refreshes it.
  """

  use GenServer
  require Logger

  # 24 hours in milliseconds
  @default_interval 24 * 60 * 60 * 1000

  # --- Client API ---

  @doc """
  Starts the InferencePriceSync GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Forces an immediate price synchronisation.
  """
  @spec sync() :: :ok | {:error, any()}
  def sync do
    GenServer.call(__MODULE__, :sync)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    # Read interval configuration (default to 24 hours)
    interval =
      Keyword.get(opts, :interval) ||
        Application.get_env(:agent_os, :sync_interval_ms, @default_interval)

    # Read fetch function from options or config
    fetch_fn =
      Keyword.get(opts, :fetch_fn) || Application.get_env(:agent_os, :models_fetch_fn) ||
        (&default_fetch_fn/0)

    # Schedule the initial non-blocking sync
    send(self(), :initial_sync)

    {:ok, %{interval: interval, fetch_fn: fetch_fn, timer: nil}}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    case perform_sync(state.fetch_fn) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:initial_sync, state) do
    _ = perform_sync(state.fetch_fn)
    timer = schedule_next_sync(state.interval)
    {:noreply, %{state | timer: timer}}
  end

  @impl true
  def handle_info(:sync_tick, state) do
    _ = perform_sync(state.fetch_fn)
    timer = schedule_next_sync(state.interval)
    {:noreply, %{state | timer: timer}}
  end

  # --- Helper Functions ---

  defp schedule_next_sync(interval) do
    Process.send_after(self(), :sync_tick, interval)
  end

  @doc """
  Performs the HTTP fetch and updates the application environment.
  """
  def perform_sync(fetch_fn) do
    case fetch_fn.() do
      {:ok, models} when is_list(models) ->
        # Retrieve fallback/existing prices
        fallback_prices = Application.get_env(:agent_os, :inference_prices, %{})

        # Parse and scale synced pricing
        synced_prices =
          Enum.reduce(models, %{}, fn model, acc ->
            case parse_model_pricing(model) do
              {:ok, model_id, price_entry} ->
                Map.put(acc, model_id, price_entry)

              _ ->
                acc
            end
          end)

        # Merge synced prices, overriding fallback values
        merged_prices = Map.merge(fallback_prices, synced_prices)

        # Update application environment cache
        Application.put_env(:agent_os, :inference_prices, merged_prices)

        Logger.info(
          "InferencePriceSync: Successfully synced pricing for #{map_size(synced_prices)} models from OpenRouter."
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "InferencePriceSync: Failed to fetch models pricing from OpenRouter: #{inspect(reason)}. Falling back to configured static prices."
        )

        {:error, reason}
    end
  end

  # Real default fetch implementation using Req
  defp default_fetch_fn do
    url = "https://openrouter.ai/api/v1/models"

    case Req.get(url) do
      {:ok, %Req.Response{status: 200, body: %{"data" => models}}} when is_list(models) ->
        {:ok, models}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse dynamic OpenRouter model entry
  defp parse_model_pricing(%{
         "id" => model_id,
         "pricing" => %{"prompt" => prompt_str, "completion" => comp_str}
       }) do
    case {parse_price(prompt_str), parse_price(comp_str)} do
      {prompt_price, comp_price} when prompt_price >= 0 and comp_price >= 0 ->
        {:ok, model_id, %{input: prompt_price, output: comp_price}}

      _ ->
        {:error, :invalid_pricing}
    end
  end

  defp parse_model_pricing(_other) do
    {:error, :invalid_schema}
  end

  @doc """
  Parses a decimal USD string into integer micro-dollars per million tokens (pico-dollars per token).
  """
  @spec parse_price(String.t() | number() | nil) :: integer()
  def parse_price(nil), do: 0
  def parse_price(val) when is_number(val), do: parse_price(to_string(val))

  def parse_price(str) when is_binary(str) do
    str = String.trim(str)

    case String.split(str, ".") do
      [int_part] ->
        case Integer.parse(int_part) do
          {int_val, _} -> int_val * 1_000_000_000_000
          _ -> 0
        end

      [int_part, frac_part] ->
        int_part = if int_part == "", do: "0", else: int_part
        padded_frac = String.pad_trailing(String.slice(frac_part, 0, 12), 12, "0")

        case {Integer.parse(int_part), Integer.parse(padded_frac)} do
          {{int_val, _}, {frac_val, _}} ->
            if int_val >= 0 do
              int_val * 1_000_000_000_000 + frac_val
            else
              int_val * 1_000_000_000_000 - frac_val
            end

          _ ->
            0
        end
    end
  end
end
