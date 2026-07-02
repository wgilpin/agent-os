# Data Model: Connector Admission + Compile-Isolated Plugins

## 1. State Store Schema

### admitted_plugins

A new StateStore instance named `"admitted_plugins"` is introduced to track human-approved third-party connectors and their credential wiring.

- **Persistence File**: `data/admitted_plugins.term` (under `StateStore` management)
- **Initial State**: `%{}`
- **Structure**: Map of module atoms to configuration options:
```elixir
%{
  module_atom() => %{
    credential_mappings: %{
      declared_credential_id :: atom() => source_env_var :: atom()
    }
  }
}
```

### Example Record

An admitted plugin named `AgentOS.Connector.MockSearch` declaring credential `:api_key` mapped to env var `SEARCH_KEY`:

```elixir
%{
  AgentOS.Connector.MockSearch => %{
    credential_mappings: %{
      api_key: :search_key
    }
  }
}
```

This mapping is resolved at action time by `AgentOS.CredentialProxy`.
