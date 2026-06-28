defmodule AgentOS.Sanitizer do
  @moduledoc """
  Validates, bounds, and normalizes untrusted incoming bookmark items.
  Drops and logs rejected items to ensure safety from injection attacks or overflow (FR-003/006).
  """

  require Logger

  @doc """
  Validates and sanitizes a single bookmark item.

  ## Parameters
    - `item`: A map representing a raw bookmark item.

  ## Returns
    - `{:ok, sanitized_item}` on success.
    - `{:error, reason}` if validation fails.
  """
  @spec sanitize(map()) :: {:ok, map()} | {:error, atom()}
  def sanitize(item) when is_map(item) do
    with {:ok, id} <- validate_id(item["id"]),
         {:ok, author} <- validate_author(item["author"]),
         {:ok, text} <- validate_text(item["text"]),
         {:ok, urls} <- validate_urls(item["urls"] || []) do
      {:ok,
       %{
         "id" => id,
         "author" => author,
         "text" => text,
         "urls" => urls
       }}
    end
  end

  def sanitize(_), do: {:error, :not_a_map}

  defp validate_id(id) do
    if is_binary(id) and id != "" and byte_size(id) <= 256 do
      {:ok, id}
    else
      {:error, :invalid_id}
    end
  end

  defp validate_author(author) do
    if is_binary(author) and author != "" and byte_size(author) <= 256 do
      {:ok, author}
    else
      {:error, :invalid_author}
    end
  end

  defp validate_text(text) do
    if is_binary(text) and text != "" and String.length(text) <= 10_000 do
      # Strip raw control characters except tab, newline, and carriage return
      sanitized_text = strip_control_chars(text)
      {:ok, sanitized_text}
    else
      {:error, :invalid_text}
    end
  end

  defp strip_control_chars(text) do
    # Regex representing standard ascii control chars excluding tab, newline, carriage return
    regex = ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]/u
    String.replace(text, regex, "")
  end

  defp validate_urls(urls) when is_list(urls) do
    if length(urls) <= 32 and Enum.all?(urls, &valid_url?/1) do
      {:ok, urls}
    else
      {:error, :invalid_urls}
    end
  end

  defp validate_urls(_), do: {:error, :invalid_urls}

  defp valid_url?(url) when is_binary(url) do
    # Simple regex verification requiring scheme http/https and a domain, maximum length 2048
    byte_size(url) <= 2048 and String.match?(url, ~r/^https?:\/\/[^\s$.?#].[^\s]*$/i)
  end

  defp valid_url?(_), do: false

  @doc """
  Filters and sanitizes a list of bookmark items. Logs dropping reasons for any failures.

  ## Parameters
    - `items`: A list of maps.

  ## Returns
    - A tuple `{sanitized_items_list, dropped_count}`.
  """
  @spec sanitize_list([map()]) :: {[map()], non_neg_integer()}
  def sanitize_list(items) when is_list(items) do
    Enum.reduce(items, {[], 0}, fn item, {acc_list, acc_dropped} ->
      case sanitize(item) do
        {:ok, sanitized} ->
          {[sanitized | acc_list], acc_dropped}

        {:error, reason} ->
          Logger.warning(
            "sanitizer rejected item: id=#{inspect(item["id"] || item)} reason=#{reason}"
          )

          {acc_list, acc_dropped + 1}
      end
    end)
    |> then(fn {acc_list, acc_dropped} ->
      {Enum.reverse(acc_list), acc_dropped}
    end)
  end

  def sanitize_list(_), do: {[], 0}
end
