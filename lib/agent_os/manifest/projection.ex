defmodule AgentOS.Manifest.Projection do
  @moduledoc """
  Deterministic projector from AgentOS.ElicitedSpec to AgentOS.Manifest.
  """

  alias AgentOS.ElicitedSpec
  alias AgentOS.Manifest
  alias AgentOS.Manifest.Grant
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
            triggers: []
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

        Enum.join(lines, "\n")
      end)
      |> Enum.join("\n")

    """
    ---
    purpose: #{inspect(manifest.purpose)}
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
