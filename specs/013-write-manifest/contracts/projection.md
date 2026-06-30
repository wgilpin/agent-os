# Contract: Manifest Projection API

Defines the deterministic interface and behavior for the manifest projector.

## Public Interface

```elixir
defmodule AgentOS.Manifest.Projection do
  @doc """
  Projects a confirmed ElicitedSpec into a Manifest struct.
  Fails loudly if the spec is unconfirmed, if a capability doesn't exist
  in the registry, or if required fields are missing.
  """
  @spec project(AgentOS.ElicitedSpec.t()) :: {:ok, AgentOS.Manifest.t()} | {:error, any()}

  @doc """
  Serializes a Manifest struct into standard YAML frontmatter + markdown body format.
  """
  @spec serialize(AgentOS.Manifest.t()) :: String.t()

  @doc """
  Writes the serialized manifest to the specified absolute path.
  """
  @spec write(AgentOS.Manifest.t(), String.t()) :: :ok | {:error, any()}

  @doc """
  Generates a deterministic capability consent view from the manifest.
  Reuses AgentOS.CapabilityRender.render/1.
  """
  @spec consent_view(AgentOS.Manifest.t()) :: String.t()
end
```

## Rejection and Guard Failures

1. **Unconfirmed Spec Rejection**:
   If the input spec has `confirmed: false` or `confirmed` is unset, the function MUST return `{:error, :not_confirmed}` or raise an error.
2. **Missing Required Fields**:
   - `purpose` must be present and not empty or whitespace-only. Otherwise, returns `{:error, :missing_purpose}`.
   - `capabilities` list must be present and contain at least one valid capability. Otherwise, returns `{:error, :empty_capabilities}`.
3. **Unknown Capability / Connector**:
   If a capability name is not registered in `AgentOS.Connector.registry/0`, the function MUST fail loudly with a runtime error detailing the unknown capability.
