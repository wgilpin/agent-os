# Data Model & Interfaces: Pluggable Connector Registry

## Entities & Type Definitions

### Connector Behaviour Callback Types

#### metadata/0
Returns the static metadata defining the capability:
- **Type**: `( -> capability())`
- **Fields**:
  - `name`: `String.t()` (unique name of the capability, e.g. `"kv_append"`)
  - `mutating?`: `boolean()` (whether execution mutates external or local state)
  - `requires_approval?`: `boolean()` (whether execution requires explicit human review)
  - `credential`: `atom() | nil` (optional credential identifier, e.g., `:outbound_token`)
  - `cost`: `integer()` (cost in micro-dollars, e.g. `2000`)

#### scope/1
Projects boundary constraints from elicitation into a manifest grant:
- **Type**: `(boundaries :: map() -> AgentOS.Manifest.Grant.t())`

#### execute/2
Executes the action with the resolved and injected secret:
- **Type**: `(action :: AgentOS.ProposedAction.t(), secret :: String.t() | nil -> :ok | {:error, term()})`

#### render/1
Renders the consent phrase representing the capability grant:
- **Type**: `(grant :: AgentOS.Manifest.Grant.t() -> String.t())`

## In-Memory Connector Registry
The dynamic registry built at boot:
- **Type**: `%{String.t() => %{module: module(), metadata: capability()}}`

## Validation Rules
- **Unique Name**: No two connector modules can register under the same name.
- **Fail-Closed Execution**: Any crash, timeout, or missing credential must result in a `{:error, reason}` outcome and must not propagate raw exceptions.
