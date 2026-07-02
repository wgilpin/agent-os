# Research: Connector Admission + Compile-Isolated Plugins

## 1. Contract Isolation (T1) Mechanics

In previous phases, connectors directly executed mutations. For instance, `KvAppend` did:
```elixir
AgentOS.StateStore.apply_action("roster_trust", {:append, :records, payload})
```
This is a violation of T1 contract isolation because it gives connector code direct access to the substrate StateStore API, giving it ambient authority.
To resolve this:
- **Connector Return Type**: Connector execution returns `{:ok, {:state_store, store_name, action}}` or `:ok`.
- **Effector Interpretation**: The `effector.ex` runs the connector in an isolated process. When the process returns the success tuple, the effector process performs the actual StateStore write:
```elixir
case result do
  {:ok, {:state_store, store_name, action}} ->
    AgentOS.StateStore.apply_action(store_name, action)
    :ok
  other ->
    other
end
```

## 2. Compile Isolation

To ensure third-party connectors do not crash the core Mix build:
- The third-party connector source lives in a separate Mix application (e.g. `test/support/plugins/test_connector/` during testing, or external repositories in production).
- It is compiled using its own `mix compile` command.
- The resulting `.beam` binaries are placed in a plugins directory (e.g., `priv/plugins/`).
- The core substrate has no compile-time dependency on these modules.

## 3. Dynamic VM Code Loading

Erlang allows dynamic module loading at runtime using `:code.load_binary/3`:
```elixir
module_atom = String.to_atom("Elixir.AgentOS.Connector.MyTool")
binary = File.read!("path/to/Elixir.AgentOS.Connector.MyTool.beam")
:code.load_binary(module_atom, 'path/to/Elixir.AgentOS.Connector.MyTool.beam', binary)
```
Once loaded, the module resides in the Erlang VM, and runtime calls can be performed via `apply(module, function, args)`.

## 4. Admission Gate Validation

To prevent un-admitted code from executing:
- We maintain a `"admitted_plugins"` StateStore mapping `module_atom => %{credential_mappings: map()}`.
- First-party modules are pre-admitted.
- The registry (`discover_and_build_registry`) filters out any module starting with `Elixir.AgentOS.Connector.` that is NOT first-party and NOT in the `"admitted_plugins"` store.
- Un-admitted modules cannot be queried or run, and their credential mappings are never loaded.
