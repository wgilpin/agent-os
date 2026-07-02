# Interface Contract: AgentOS.Connector Behaviour

This document outlines the API contracts and typespecs exposed by the `AgentOS.Connector` behaviour module and registry interface.

## Module Interface

Every dynamic capability module must adopt the `AgentOS.Connector` behaviour:

```elixir
defmodule AgentOS.Connector do
  @type capability :: %{
          name: String.t(),
          mutating?: boolean(),
          requires_approval?: boolean(),
          credential: atom() | nil,
          cost: integer()
        }

  @callback metadata() :: capability()
  @callback scope(boundaries :: map()) :: AgentOS.Manifest.Grant.t()
  @callback execute(action :: AgentOS.ProposedAction.t(), secret :: String.t() | nil) :: :ok | {:error, any()}
  @callback render(grant :: AgentOS.Manifest.Grant.t()) :: String.t()
end
```

## Public Registry API

The `AgentOS.Connector` module exposes the following query functions to the substrate:

### registry/0
Returns the full map of registered capability metadata maps.
- **Spec**: `@spec registry() :: %{String.t() => capability()}`

### get/1
Retrieves a specific capability's metadata map.
- **Spec**: `@spec get(name :: String.t()) :: {:ok, capability()} | {:error, :unknown_connector}`

### get_module/1
Retrieves the backing module implementing the capability.
- **Spec**: `@spec get_module(name :: String.t()) :: {:ok, module()} | {:error, :unknown_connector}`
