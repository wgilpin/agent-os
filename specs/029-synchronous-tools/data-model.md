# Data Model: Synchronous Tools + Web Search

## 1. Schema Modifications

### Connector Capability Metadata

The `capability` map returned by `Connector.metadata/0` is extended to support tool specifications.

```elixir
@type capability :: %{
        name: String.t(),
        mutating?: boolean(),
        requires_approval?: boolean(),
        credential: atom() | nil,
        cost: integer(),
        # New optional field for tool integration
        tool_declaration: map() | nil
      }
```

- `tool_declaration`: A JSON-serializable map conforming to the OpenAI Function Declaration schema. If `nil` or omitted, the connector is treated as effect-only.

## 2. State Store Actions

### spend_ledger mutations

- **Location**: `spend_ledger` StateStore.
- **Type**: Map of agent name to spend record: `%{spent: integer(), window_start: DateTime.t()}`.
- **Trigger**: Every tool execution synchronously increments the agent's `spent` micro-dollar accumulator in the `spend_ledger` prior to returning completion context.
- **Enforcement**: Prior to tool call execution, a check is performed. If `entry.spent + tool.cost >= manifest.spend.cap`, the run is terminated with `{:breach, :spend}`.
