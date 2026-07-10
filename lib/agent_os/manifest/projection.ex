defmodule AgentOS.Manifest.Projection do
  @moduledoc """
  Deterministic projector from AgentOS.ElicitedSpec to AgentOS.Manifest.
  """

  alias AgentOS.ElicitedSpec
  alias AgentOS.Manifest

  alias AgentOS.Manifest.Spend
  alias AgentOS.Connector

  @doc """
  Projects a confirmed ElicitedSpec into a Manifest struct.
  """
  @spec project(ElicitedSpec.t()) :: {:ok, Manifest.t()} | {:error, any()}
  def project(%ElicitedSpec{confirmed: false}) do
    {:error, :not_confirmed}
  end

  def project(%ElicitedSpec{} = spec) do
    cond do
      is_nil(spec.purpose) or String.trim(spec.purpose) == "" ->
        {:error, :missing_purpose}

      is_nil(spec.capabilities) or spec.capabilities == [] ->
        {:error, :empty_capabilities}

      # A zero (or negative) cap produces an inert agent: the spend pre-check blocks
      # every inference AND every connector call (spent 0 >= cap 0). Refuse loudly at
      # projection instead of generating and judging an agent that can never act.
      is_nil(spec.spend_limits) or is_nil(spec.spend_limits.dollar_cap) or
          spec.spend_limits.dollar_cap <= 0 ->
        {:error, :non_positive_spend_cap}

      true ->
        try do
          grants = Enum.map(spec.capabilities, &map_capability_to_grant!(&1, spec.boundaries))

          spend = %Spend{
            cap: round(spec.spend_limits.dollar_cap * 1_000_000),
            window: :daily,
            on_breach: :kill
          }

          manifest = %Manifest{
            purpose: spec.purpose,
            owner: "human",
            supervision: "restart-once-and-alert",
            grants: grants,
            spend: spend,
            mounts: [],
            triggers: spec.triggers || []
          }

          {:ok, manifest}
        rescue
          e in RuntimeError ->
            {:error, e.message}
        end
    end
  end

  @doc """
  Serializes a Manifest struct into standard YAML frontmatter + markdown body format.
  """
  @spec serialize(Manifest.t()) :: String.t()
  def serialize(%Manifest{} = manifest) do
    grants_yaml =
      manifest.grants
      |> Enum.map(fn grant ->
        lines = ["  - connector: #{grant.connector}"]

        lines =
          if grant.recipients do
            lines ++ ["    recipients: #{inspect(grant.recipients)}"]
          else
            lines
          end

        lines =
          if grant.methods do
            lines ++ ["    methods: #{inspect(grant.methods)}"]
          else
            lines
          end

        lines =
          if grant.handle do
            lines ++ ["    handle: #{inspect(grant.handle)}"]
          else
            lines
          end

        lines =
          if grant.namespace do
            lines ++ ["    namespace: #{inspect(grant.namespace)}"]
          else
            lines
          end

        lines =
          if grant.path do
            lines ++ ["    path: #{inspect(grant.path)}"]
          else
            lines
          end

        Enum.join(lines, "\n")
      end)
      |> Enum.join("\n")

    triggers_yaml =
      if manifest.triggers == [] or is_nil(manifest.triggers) do
        "[]"
      else
        "\n" <>
          (manifest.triggers
           |> Enum.map(fn t ->
             case Map.get(t, :type) || Map.get(t, "type") do
               :startup ->
                 "  - type: startup"

               "startup" ->
                 "  - type: startup"

               :time ->
                 "  - type: time\n    at: \"#{t.at}\""

               "time" ->
                 "  - type: time\n    at: \"#{Map.get(t, :at) || Map.get(t, "at")}\""

               :event ->
                 "  - type: event\n    name: \"#{t.name}\""

               "event" ->
                 "  - type: event\n    name: \"#{Map.get(t, :name) || Map.get(t, "name")}\""

               :message ->
                 "  - type: message"

               "message" ->
                 "  - type: message"

               other ->
                 raise "Unsupported trigger type: #{inspect(other)}"
             end
           end)
           |> Enum.join("\n"))
      end

    """
    ---
    purpose: #{inspect(manifest.purpose)}
    triggers: #{triggers_yaml}
    grants:
    #{grants_yaml}
    spend:
      cap: #{manifest.spend.cap}
      window: #{manifest.spend.window}
      on_breach: #{manifest.spend.on_breach}
    owner: #{manifest.owner}
    supervision: #{manifest.supervision}
    ---
    # #{manifest.purpose}
    """
  end

  @doc """
  Writes the serialized manifest to the specified path.
  """
  @spec write(Manifest.t(), String.t()) :: :ok | {:error, any()}
  def write(%Manifest{} = manifest, path) do
    cond do
      String.contains?(path, "agents/") ->
        {:error, :invalid_path}

      true ->
        content = serialize(manifest)
        File.write(path, content)
    end
  end

  @doc """
  Generates a deterministic capability consent view from the manifest.
  Reuses AgentOS.CapabilityRender.render/1.
  """
  @spec consent_view(Manifest.t()) :: String.t()
  def consent_view(%Manifest{} = manifest) do
    AgentOS.CapabilityRender.render(manifest)
  end

  # Private helpers

  defp map_capability_to_grant!(cap_name, boundaries) do
    case Connector.get_module(cap_name) do
      {:ok, mod} ->
        mod.scope(boundaries)

      {:error, :unknown_connector} ->
        raise RuntimeError, "Connector '#{cap_name}' is missing from the capability registry."
    end
  end
end
