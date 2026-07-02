# Research: Approval Flag Split

## 1. Codebase Audit for `requires_approval?`

A grep search across the codebase revealed occurrences of the legacy `requires_approval?` flag in these key modules:
1. `lib/agent_os/connector.ex` (behaviour definition and registry scan)
2. `lib/agent_os/gate.ex` (approval checks to decide if action is parked)
3. `lib/agent_os/capability_render.ex` (badging and classification logic)
4. All four existing connectors (`external_send`, `gmail_draft`, `gmail_read`, `kv_append` under `lib/agent_os/connector/`)
5. Accompanying test suites (`capability_render_test.exs`, `connector_test.exs`, `gate_test.exs`, `provisioner_test.exs`, `run_supervisor_test.exs`, `consent_live_test.exs`)

## 2. Gate Parking Logic

In `lib/agent_os/gate.ex`, the approval check currently is:
```elixir
if Map.get(connector, :requires_approval?, false) do
  {:needs_approval, grant}
else
  {:approve, grant}
end
```

To migrate to the split-flag model, the check is refactored to look up `:requires_runtime_approval?`:
```elixir
if Map.get(connector, :requires_runtime_approval?, false) do
  {:needs_approval, grant}
else
  {:approve, grant}
end
```

## 3. Provisioner Deploy Safety

Build-time consent checks in `AgentOS.Provisioner.deploy/3` use `envelope_predicate?/2` to decide if an agent should be auto-deployed without a human review blocker.
Currently, this is derived from whether the connector danger tier is `:external` or mutating.
To enforce explicit build-time consent:
- `envelope_predicate?/2` is extended to inspect each grant. If `requires_deploy_consent?` is set to `true` on the registry entry for any granted connector, the envelope returns `false` (meaning the deployment must block on human review/approval).

## 4. Capability Rendering

In `lib/agent_os/capability_render.ex`, the `danger_tier/1` classification checks:
```elixir
is_nil(cap.credential) and not cap.requires_runtime_approval? and cap.cost == 0 -> :local
```
Additionally, both `requires_deploy_consent?` and `requires_runtime_approval?` will render as text badges in the formatting output of `format/1` (e.g. `[DEPLOY_CONSENT, RUNTIME_APPROVAL]`) to provide clear visual indicators to administrators.
