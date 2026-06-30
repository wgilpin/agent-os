# Contract: `AgentOS.CapabilityRender`

Public interface for the deterministic capability render. Substrate-side, pure, no side effects,
no LLM, no network, no Docker.

## `entries/1`

```text
@spec entries(AgentOS.Manifest.t()) :: [AgentOS.CapabilityRender.Entry.t()]
entries(manifest)
```

Maps each grant in `manifest.grants` to exactly one `Entry`, in grant order.

**Guarantees**:
- **TOTAL**: `length(entries(manifest)) == length(manifest.grants)`. No grant suppressed, merged,
  or hidden. (FR-001, SC-001)
- **FAITHFUL**: each `Entry` is derived from its grant's fields + the registry; adding/removing/
  rescoping a grant changes the result correspondingly. No separately stored description. (FR-002,
  FR-003, SC-002)
- **DANGER from registry only**: `Entry.danger` is computed from `Connector.registry()[connector]`
  via the danger-tier rule — never from the author or invented. (FR-004, FR-006)
- **Phrase mechanical**: `Entry.phrase` is a static lookup by generic capability name, with a
  deterministic fallback when unmapped (`phrase_source: :fallback`). No model authored it. (FR-007,
  FR-008, FR-011)

**Errors (loud)**:
- If `connector` is absent from `Connector.registry()` at render time → raises (Constitution VI,
  FR-011). Never returns a guessed danger or silently drops the grant.

## `format/1`

```text
@spec format([AgentOS.CapabilityRender.Entry.t()]) :: String.t()
format(entries)
```

Deterministic presentation of entries for the standing inventory.

**Guarantees**:
- One line per entry; `:external` entries are visually/semantically distinct from `:local` and
  `:read_only` (FR-005, SC-003).
- Author-set scope (recipients/methods) shown when present (FR-003).
- Byte-identical output for identical input (FR-007, SC-004).
- Empty entry list → an explicit "no capabilities granted" line (edge case), not a blank string.

## `render/1` (convenience)

```text
@spec render(AgentOS.Manifest.t()) :: String.t()
render(manifest)   # == format(entries(manifest))
```

The single call `AgentOS.Inventory.render/1` uses to replace the raw `inspect(manifest.grants)`
line.

## Contract tests (must exist, all no-live-deps)

| # | Property | Assertion |
|---|----------|-----------|
| C1 | TOTAL | `entries(discovery_manifest)` has one entry per grant; both `kv_append` and `external_send` present. |
| C2 | TOTAL (send never dropped) | A manifest holding an `external_send` grant always yields an entry for it. |
| C3 | DANGER-RANKED (field) | `external_send` entry is `:external`; `kv_append` entry is `:local`; `:external` > `:local`. |
| C3f | DANGER-RANKED (rendered) | The formatted line for `external_send` carries a danger marker absent from the `kv_append` line — danger survives into the text, not just `Entry.danger` (FR-005/SC-003). |
| C4 | DANGER from registry | Overriding `Connector.registry()` to make a connector free/credential-less changes its tier; author scope changes do NOT change tier. |
| C5 | FAITHFUL — add | Adding a grant adds an entry. |
| C6 | FAITHFUL — remove | Removing a grant removes its entry. |
| C7 | FAITHFUL — rescope | Changing recipients/methods changes the entry's scope echo. |
| C8 | NEVER-LLM / deterministic | `format(entries(m))` called twice is byte-identical. |
| C9 | Fallback | A granted connector with no phrase-map entry renders a fallback phrase, `phrase_source: :fallback`, still danger-tagged — not dropped. |
| C10 | Loud failure | A grant whose connector is missing from the registry raises rather than dropping/guessing. |
| C11 | Agent-agnostic | The same capability renders the same phrase + tier regardless of agent/manifest. |
| C12 | Surface | `AgentOS.Inventory.render/1` output contains the capability view (readable phrases) and no longer dumps raw `%AgentOS.Manifest.Grant{}` structs. |
