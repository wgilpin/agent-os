defmodule AgentOS.InferencePrice do
  @moduledoc """
  Pure helper functions for per-model price lookup and micro-dollar spend calculations.
  Calculates all dollar values as exact integers in micro-dollars (1e-6 USD).
  """

  @type price_entry :: %{
          # input price in micro-dollars per million tokens (pico-dollars per token)
          input: pos_integer(),
          # output price in micro-dollars per million tokens (pico-dollars per token)
          output: pos_integer()
        }

  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer()
        }

  @doc """
  Looks up a model's input/output token price in a given prices table.
  Returns `{:ok, price_entry}` or `{:error, :unpriced_model}`.
  """
  @spec lookup(map(), String.t()) :: {:ok, price_entry()} | {:error, :unpriced_model}
  def lookup(prices, model) when is_map(prices) and is_binary(model) do
    case Map.fetch(prices, model) do
      {:ok, %{input: input, output: output} = entry}
      when is_integer(input) and is_integer(output) ->
        {:ok, entry}

      _ ->
        {:error, :unpriced_model}
    end
  end

  @doc """
  Computes the total micro-dollars spent for a given token usage and price entry.
  Calculates in pico-dollars internally and rounds up to the nearest integer micro-dollar.
  Returns the exact integer micro-dollars.
  """
  @spec micro_dollars(usage(), price_entry()) :: integer()
  def micro_dollars(usage, price) when is_map(usage) and is_map(price) do
    pico_dollars = usage.input_tokens * price.input + usage.output_tokens * price.output
    div(pico_dollars + 999_999, 1_000_000)
  end
end
