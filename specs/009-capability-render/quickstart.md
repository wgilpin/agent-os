# Quickstart: Deterministic Capability Render

## What this is

A pure substrate-side function that turns an agent's manifest grants into a faithful, total,
danger-ranked, normie-readable capability view, surfaced in the standing inventory. No LLM, no
network, no Docker.

## Run it (worked example — the existing discovery agent)

```elixir
{:ok, manifest} = AgentOS.Manifest.load("manifests/discovery.md")
IO.puts(AgentOS.CapabilityRender.render(manifest))
```

The discovery agent grants `kv_append` (local, lower danger) and `external_send` (egress, higher
danger). Expect a readable line per capability with `external_send` visibly marked as the riskier
one (its danger comes from the registry: it mutates external state, needs the `outbound_token`
credential, requires approval, and costs 2000µ$).

It also shows up automatically in the standing inventory:

```elixir
IO.puts(AgentOS.Inventory.render())
# ... CAPABILITIES: block replaces the old raw `GRANTS: [%AgentOS.Manifest.Grant{...}]` line
```

## Run the tests

```bash
mix test test/agent_os/capability_render_test.exs
mix test test/agent_os/inventory_test.exs
```

All tests run with no live dependencies. Tests that exercise danger-from-registry override the
registry with `Application.put_env(:agent_os, :connector_registry, %{...})` and restore it in
`on_exit` (same pattern as `test/agent_os/run_supervisor_test.exs`).

## The four properties, where to see them

| Property | Where proven |
|----------|--------------|
| FAITHFUL | `entries/1` derives from grant fields + registry; add/remove/rescope tests (C5–C7). |
| TOTAL | one entry per grant; send-grant-never-dropped test (C1, C2). |
| DANGER-RANKED | tier from registry; `external_send` `:external` > `kv_append` `:local` (C3, C4). |
| NEVER LLM-WRITTEN | static phrase map + deterministic byte-identical output (C8, C11). |

## Quality gates before saving

- `mix format` and Credo clean.
- Every function has a purpose comment; the danger-tier rule is commented at its definition.
- No remote calls in any test.

## Scope reminder

This plan only READS the manifest, grants, registry, and danger metadata. It does not touch the
gate, manifest schema, enforcement, or the registry's danger metadata, and adds no new connector,
grant, or capability type. Review modes, the deploy/consent screen, and the conformance auditor are
later plans (04-02, 04-03, 04-09).
