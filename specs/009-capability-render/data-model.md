# Phase 1 Data Model: Deterministic Capability Render

This feature is a pure transform; it persists nothing. The "data model" is the in-memory shapes
the render consumes and produces.

## Consumed (existing, read-only)

### `AgentOS.Manifest.Grant` (unchanged)

```text
%AgentOS.Manifest.Grant{
  connector:  String.t(),          # generic capability name, e.g. "kv_append", "external_send"
  recipients: [String.t()] | nil,  # author-set scope
  methods:    [String.t()] | nil   # author-set scope
}
```

### Connector capability (registry entry, unchanged)

Read via `AgentOS.Connector.registry()` → `%{String.t() => capability}` where:

```text
%{
  name:               String.t(),
  mutating?:          boolean(),
  requires_approval?: boolean(),
  credential:         atom() | nil,
  cost:               integer()    # micro-dollars; 0 == free
}
```

This is the ONLY source of danger. The render reads it; it never writes it.

## Produced (new)

### `AgentOS.CapabilityRender.Entry`

One per manifest grant. Strong-typed (Constitution V), no bare maps.

```text
%AgentOS.CapabilityRender.Entry{
  connector:    String.t(),                       # generic capability name (from the grant)
  phrase:       String.t(),                        # human-readable, from the phrase map (or fallback)
  danger:       :read_only | :local | :external,   # derived from registry danger metadata only
  recipients:   [String.t()] | nil,                # echoed from the grant (faithful scope)
  methods:      [String.t()] | nil,                # echoed from the grant (faithful scope)
  phrase_source: :mapped | :fallback               # :fallback when no phrase-map entry existed
}
```

**Invariants**:
- `entries(manifest)` returns exactly one `Entry` per `manifest.grants` element, in the same order
  (TOTAL, FR-001; stable ordering).
- `danger` is a pure function of the registry entry for `connector` — independent of `recipients`,
  `methods`, the manifest author, or any text (FR-006, FR-004).
- `phrase` is a pure function of `connector` (FR-007, FR-008); identical for the same capability
  across all agents.

## Danger tier rule (authoritative)

```text
danger_tier(cap):
  if not cap.mutating?                                  -> :read_only
  else if cap.credential == nil
       and not cap.requires_approval?
       and cap.cost == 0                                -> :local
  else                                                  -> :external
```

Ordering for "more dangerous than" comparisons (FR-004): `:read_only < :local < :external`.

Discovery agent: `kv_append → :local`, `external_send → :external`. The render MUST make
`external_send` visibly out-rank `kv_append` (FR-005).

## Phrase map (new, render-owned, generic-keyed)

```text
@phrases %{
  "kv_append"     => "WRITE TO YOUR LOCAL STATE STORE",
  "external_send" => "SEND MESSAGES OUT TO EXTERNAL RECIPIENTS"
}
```

- Keyed by generic capability name (agent-agnostic, FR-008).
- A connector not present here renders a deterministic fallback (e.g.
  `"USE CAPABILITY: <connector>"`) with `phrase_source: :fallback`, still danger-tagged, never
  dropped (FR-011). Exact phrase wording is a presentation detail; the worked example uses the two
  above. (The roadmap's Gmail wording is illustrative of a future agent/connector, not added here.)

## Formatted output shape (presentation layer)

`format(entries)` produces the text block placed in the standing inventory under a
`CAPABILITIES:` heading — one line per entry, danger visibly marked (e.g. a tier label / symbol),
scope shown when present. Exact glyphs/labels are fixed at implementation time but MUST satisfy:
`:external` is visually distinct from `:local`/`:read_only` (FR-005), and the output is
byte-identical for identical input (FR-007 / SC-004).
