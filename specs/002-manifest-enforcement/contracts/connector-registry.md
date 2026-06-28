# Contract: Connector Capability Registry

The substrate's source of truth for **how dangerous each capability is**. A connector is a
generic substrate capability (`kv_append`, `external_send`) — never an agent's domain verb
(Principle IX). The manifest *grants and scopes* connectors; the registry *classifies* them. The
two are separate on purpose: the author decides reach (which connector, to whom), the substrate
decides danger (approval, credential, cost). An author — human now, machine in v3 — cannot
downgrade a connector's danger from the manifest (D9, FR-002).

## Connector behaviour & registry entry

```elixir
# A connector implements execution; the registry holds its intrinsic classification.
@type capability :: %{
        name: String.t(),            # generic registry key; never an agent verb
        mutating?: boolean(),        # mutates external state?
        requires_approval?: boolean(),# every action on this connector parks for approval (FR-015)
        credential: atom() | nil,    # capability id the CredentialProxy injects (FR-008); nil = none
        cost: number()               # per-action spend cost summed by the meter (FR-010a)
      }
```

## Registry for v2 (discovery agent)

| connector | mutating? | requires_approval? | credential | cost | backing |
|-----------|-----------|--------------------|------------|------|---------|
| `kv_append` | true (local state) | false | `nil` | 1 | `StateStore` append (replaces hard-coded `record_signal`/`append_digest`) |
| `external_send` | true (external) | true | `:outbound_token` | 2 | **mock sink** (deterministic, no live dependency — Principle IV) |

## Rules

- **Author cannot override danger**: `requires_approval?`, `credential`, and `cost` are read only
  from the registry; a manifest grant has no field that can change them (D9).
- **Generic names only**: registry keys are capability names, not agent concepts — this is what
  keeps `lib/agent_os/` agent-agnostic and de-leaks the current `Effector` (which today matches
  `"record_signal"`/`"append_digest"` literally).
- **Effector dispatch**: on an approved action the effector dispatches by the grant's connector to
  the registry-backed implementation; for a connector with a `credential`, the `CredentialProxy`
  injects the secret inside that call.
- **Provisioning**: a manifest granting a connector absent from the registry fails provisioning
  loudly (FR-016).
- **Deferred refinement (not v2)**: "escalate-only" — a manifest may *add* approval to a connector
  that doesn't require it, but never *remove* it. v2 treats approval as purely registry-intrinsic.
