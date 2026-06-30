# Data Model: Manifest Projection

Describes the types, structures, and mapping transformations between the `ElicitedSpec` input and the `Manifest` output.

## Input: `AgentOS.ElicitedSpec`

Defines the structure produced by Stage 1 elicitation.

```elixir
defmodule AgentOS.ElicitedSpec do
  defstruct [
    :purpose,
    :capabilities,
    boundaries: %{egress_domains: [], target_locations: []},
    spend_limits: %{dollar_cap: 0.0, token_limit: 0},
    confirmed: false
  ]
end
```

## Output: `AgentOS.Manifest`

Defines the v2 schema-conforming manifest.

```elixir
defmodule AgentOS.Manifest do
  defstruct [:purpose, :triggers, :grants, :mounts, :spend, :owner, :supervision]
end
```

### Spend Sub-struct

```elixir
defmodule AgentOS.Manifest.Spend do
  defstruct [:cap, :window, :on_breach]
end
```

### Grant Sub-struct

```elixir
defmodule AgentOS.Manifest.Grant do
  defstruct [:connector, :recipients, :methods]
end
```

## Transformation Mapping Rules

| ElicitedSpec Field | Manifest Target | Transformation Logic / Constant |
| :--- | :--- | :--- |
| `purpose` | `purpose` | Unchanged string |
| `confirmed` | *(Guard)* | Must be `true`; error otherwise |
| `capabilities` | `grants` | Map each to `Grant` struct (registry verified) |
| `boundaries.egress_domains` | `grants.recipients` | Sorted list (only for `external_send`) |
| `spend_limits.dollar_cap` | `spend.cap` | `round(dollar_cap * 1_000_000)` (micro-dollars) |
| *N/A* | `owner` | `"human"` (constant) |
| *N/A* | `supervision` | `"restart-once-and-alert"` (constant) |
| *N/A* | `spend.window` | `:daily` (constant) |
| *N/A* | `spend.on_breach` | `:kill` (constant) |
| *N/A* | `triggers` | `[]` (constant) |
| *N/A* | `mounts` | `[]` (constant) |
