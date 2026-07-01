defmodule AgentOS.InferencePriceSyncTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias AgentOS.InferencePriceSync

  setup do
    # Capture application environment state to restore on exit
    old_prices = Application.get_env(:agent_os, :inference_prices)

    on_exit(fn ->
      if old_prices do
        Application.put_env(:agent_os, :inference_prices, old_prices)
      else
        Application.delete_env(:agent_os, :inference_prices)
      end
    end)

    :ok
  end

  describe "parse_price/1" do
    test "parses integers correctly" do
      assert InferencePriceSync.parse_price("2") == 2_000_000_000_000
      assert InferencePriceSync.parse_price(5) == 5_000_000_000_000
      assert InferencePriceSync.parse_price("0") == 0
    end

    test "parses decimals correctly" do
      # 0.00000015 USD per token = 150_000 pico-dollars per token
      assert InferencePriceSync.parse_price("0.00000015") == 150_000
      # 0.000002 USD per token = 2_000_000 pico-dollars per token
      assert InferencePriceSync.parse_price("0.000002") == 2_000_000
      assert InferencePriceSync.parse_price("0.1") == 100_000_000_000
      assert InferencePriceSync.parse_price("0.0") == 0
    end

    test "handles missing or malformed input gracefully" do
      assert InferencePriceSync.parse_price(nil) == 0
      assert InferencePriceSync.parse_price("") == 0
      assert InferencePriceSync.parse_price("invalid") == 0
    end
  end

  describe "sync and merge logic" do
    test "overwrites/merges prices correctly on success" do
      # Seed initial fallback config
      Application.put_env(:agent_os, :inference_prices, %{
        "model-fallback-only" => %{input: 10_000_000, output: 30_000_000},
        "model-to-override" => %{input: 5_000_000, output: 5_000_000}
      })

      # Mock fetch fn returning a list of model specs
      mock_fetch = fn ->
        {:ok,
         [
           %{
             "id" => "model-to-override",
             "pricing" => %{"prompt" => "0.00000015", "completion" => "0.00000060"}
           },
           %{
             "id" => "model-synced-only",
             "pricing" => %{"prompt" => "0.000002", "completion" => "0.000008"}
           }
         ]}
      end

      # Run sync manually
      assert :ok = InferencePriceSync.perform_sync(mock_fetch)

      # Check updated application environment cache
      prices = Application.get_env(:agent_os, :inference_prices)

      # 1. Fallback only model is preserved
      assert Map.get(prices, "model-fallback-only") == %{input: 10_000_000, output: 30_000_000}

      # 2. Override model is updated with new rates
      assert Map.get(prices, "model-to-override") == %{input: 150_000, output: 600_000}

      # 3. New synced-only model is added
      assert Map.get(prices, "model-synced-only") == %{input: 2_000_000, output: 8_000_000}
    end

    test "retains existing cache and logs warnings on failure" do
      initial_prices = %{"model-fallback-only" => %{input: 10_000_000, output: 30_000_000}}
      Application.put_env(:agent_os, :inference_prices, initial_prices)

      mock_fetch_fail = fn ->
        {:error, :timeout}
      end

      # Run sync and assert error return + captured log warnings
      log =
        capture_log(fn ->
          assert {:error, :timeout} = InferencePriceSync.perform_sync(mock_fetch_fail)
        end)

      assert log =~ "Failed to fetch models pricing from OpenRouter"

      # Verify cache was not wiped or modified
      assert Application.get_env(:agent_os, :inference_prices) == initial_prices
    end
  end

  describe "GenServer lifecycle and periodic timer" do
    test "schedules and triggers periodic refresh ticks" do
      parent = self()

      # Custom mock fetch function that sends a signal to test process
      mock_fetch = fn ->
        send(parent, :tick)
        {:ok, []}
      end

      # Start GenServer with a fast interval (50ms)
      {:ok, _pid} = start_supervised({InferencePriceSync, interval: 50, fetch_fn: mock_fetch})

      # Should sync immediately at boot
      assert_receive :tick, 200

      # Should sync again after 50ms tick
      assert_receive :tick, 200

      # Clean up
      stop_supervised(InferencePriceSync)
    end
  end
end
