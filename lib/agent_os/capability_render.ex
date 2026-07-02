defmodule AgentOS.CapabilityRender do
  @moduledoc """
  Substrate-side deterministic render for agent capability manifest grants.
  """

  alias AgentOS.CapabilityRender.Entry
  alias AgentOS.Manifest

  # Phrasing map keyed by generic capability names.
  @phrases %{
    "kv_append" => "WRITE TO YOUR LOCAL STATE STORE",
    "external_send" => "SEND MESSAGES OUT TO EXTERNAL RECIPIENTS",
    "gmail_read" => "READ INCOMING EMAILS FROM GMAIL",
    "gmail_draft" => "CREATE DRAFT EMAILS IN GMAIL"
  }

  @spec entries(Manifest.t()) :: [Entry.t()]
  def entries(manifest) do
    # Read the connector registry (accessor allows runtime overrides in test and enforcement)
    registry = AgentOS.Connector.registry()

    Enum.map(manifest.grants, fn grant ->
      connector_name = grant.connector

      case Map.fetch(registry, connector_name) do
        {:ok, cap} ->
          danger = danger_tier(cap)

          {phrase, phrase_source} =
            case AgentOS.Connector.get_module(connector_name) do
              {:ok, mod} ->
                {mod.render(grant), :mapped}

              _ ->
                case Map.fetch(@phrases, connector_name) do
                  {:ok, mapped_phrase} -> {mapped_phrase, :mapped}
                  :error -> {"USE CAPABILITY: #{connector_name}", :fallback}
                end
            end

          %Entry{
            connector: connector_name,
            phrase: phrase,
            danger: danger,
            recipients: grant.recipients,
            methods: grant.methods,
            phrase_source: phrase_source
          }

        :error ->
          # Loud failure when connector is missing from registry (Constitution VI, FR-011)
          raise RuntimeError,
                "Connector '#{connector_name}' is missing from the capability registry."
      end
    end)
  end

  @spec format([Entry.t()]) :: String.t()
  def format([]) do
    "CAPABILITIES:\n  - no capabilities granted\n"
  end

  def format(entries) do
    lines =
      Enum.map(entries, fn entry ->
        if String.contains?(entry.phrase, " (") or String.starts_with?(entry.phrase, "[") do
          "  - #{entry.phrase}"
        else
          badge = if entry.danger == :external, do: "[EXTERNAL] ", else: ""

          scope_str =
            cond do
              entry.recipients && entry.methods ->
                " (recipients: #{inspect(entry.recipients)}, methods: #{inspect(entry.methods)})"

              entry.recipients ->
                " (recipients: #{inspect(entry.recipients)})"

              entry.methods ->
                " (methods: #{inspect(entry.methods)})"

              true ->
                ""
            end

          "  - #{badge}#{entry.phrase}#{scope_str}"
        end
      end)

    "CAPABILITIES:\n" <> Enum.join(lines, "\n") <> "\n"
  end

  @spec render(Manifest.t()) :: String.t()
  def render(manifest) do
    format(entries(manifest))
  end

  # Computes the danger tier of a connector based strictly on registry metadata.
  # Rules (FR-004, FR-006, Constitution X):
  # - if not mutating -> :read_only
  # - if mutating, no credential, no approval, zero cost -> :local
  # - otherwise -> :external
  defp danger_tier(cap) do
    cond do
      not cap.mutating? -> :read_only
      is_nil(cap.credential) and not cap.requires_approval? and cap.cost == 0 -> :local
      true -> :external
    end
  end
end
