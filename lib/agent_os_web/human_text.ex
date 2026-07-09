defmodule AgentOSWeb.HumanText do
  @moduledoc """
  Shared helpers that turn machine identifiers (file slugs, capability
  phrases, method lists) into human-readable UI text.
  """

  # Proper nouns that keep their capitalisation when an all-caps phrase is
  # softened to sentence case.
  @proper_nouns %{"discord" => "Discord", "gmail" => "Gmail"}

  @doc """
  Turns a file-slug agent name into a readable, length-capped label.
  The full slug should stay available via the element's title attribute.
  """
  def humanize_name(nil), do: ""

  def humanize_name(name) do
    readable =
      name
      |> String.replace("_", " ")
      |> String.trim()
      |> String.capitalize()

    if String.length(readable) > 72 do
      String.slice(readable, 0, 71) <> "…"
    else
      readable
    end
  end

  @doc """
  Strips machine badges/scope annotations from a capability phrase so the UI
  shows plain language. The danger tier and methods are rendered separately.
  """
  def display_phrase(phrase) do
    phrase
    |> String.replace(~r/^(\[[A-Z_]+\]\s*)+/, "")
    |> String.replace(~r/\s*\([^)]*\)\s*$/, "")
    |> String.trim()
    |> soften_case()
  end

  @doc """
  Renders a list of method/recipient terms into a friendly comma list.
  """
  def humanize_terms(terms) when is_list(terms), do: Enum.join(terms, ", ")
  def humanize_terms(term), do: to_string(term)

  # Turns an ALL-CAPS phrase into sentence case (proper nouns preserved).
  # Phrases that already contain lowercase letters are left untouched.
  defp soften_case(text) do
    if String.match?(text, ~r/[a-z]/) do
      text
    else
      text
      |> String.downcase()
      |> String.split(" ")
      |> Enum.map(&Map.get(@proper_nouns, &1, &1))
      |> Enum.join(" ")
      |> upcase_first()
    end
  end

  defp upcase_first(""), do: ""

  defp upcase_first(text) do
    {head, tail} = String.split_at(text, 1)
    String.upcase(head) <> tail
  end
end
