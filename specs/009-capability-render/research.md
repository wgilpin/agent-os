# Phase 0 Research: Deterministic Capability Render

All "NEEDS CLARIFICATION" items resolved below. No live research (web/model) required — every
decision is grounded in the existing codebase.

## R1 — Where does the human-readable phrase mapping live?

**Decision**: A hard-coded module-level map in the new `AgentOS.CapabilityRender` module, keyed
by the generic capability name (the connector string, e.g. `"kv_append"`, `"external_send"`).

**Rationale**:
- The spec's out-of-scope explicitly forbids changing "the connector registry's danger metadata".
  A human-readable phrase is *not* danger metadata, but to avoid any ambiguity and keep the
  registry change-free, the phrase map is kept in the render module.
- Keying by generic capability name (not by agent or by manifest field) satisfies agent-agnostic
  (Constitution IX) and FR-008: the same capability renders identically no matter which agent
  holds it.
- It is a static compile-time literal — mechanical, never model-authored (FR-007).

**Alternatives considered**:
- *Add a `:phrase` field to the registry capability map.* Rejected: touches the registry (scope
  risk) and conflates danger metadata with presentation. Can be revisited in a later plan if the
  consent screen wants the registry to own phrasing.
- *Generate phrasing from connector name programmatically* (e.g. titlecase). Rejected: produces
  unreadable phrases ("Kv Append") and is not normie-readable; a curated phrase per capability is
  required.

## R2 — How is the danger tier computed, and from which registry accessor?

**Decision**: A deterministic `danger_tier/1` over the registry capability map yielding three
ordered tiers:

| Tier | Rule (from registry fields) | Discovery agent example |
|------|------------------------------|-------------------------|
| `:read_only` | `mutating? == false` | (none on this agent) |
| `:local` | `mutating? == true` AND `credential == nil` AND `requires_approval? == false` AND `cost == 0` | `kv_append` |
| `:external` | `mutating? == true` AND (`credential != nil` OR `requires_approval? == true` OR `cost > 0`) | `external_send` |

Read the registry via **`AgentOS.Connector.registry()`** (the `Application.get_env`-overridable
accessor), NOT `Connector.get/1` (which reads the compile-time `@registry` only).

**Rationale**:
- The danger tier is derived solely from registry fields → satisfies FR-006 / Constitution X (the
  thing being granted never classifies its own danger; the author never sets it).
- `Connector.registry()` is the exact accessor the enforcement path uses (`effector.ex:27`,
  `run_worker.ex:252`). Reading danger from the same source guarantees FAITHFUL: the displayed
  danger cannot drift from the cost/credential behaviour the chokepoint actually enforces, and
  test registry overrides flow through to the render too.
- Three tiers are the minimum that distinguishes the two real-world cases on the existing agent
  (`kv_append` local vs `external_send` egress) while leaving a `:read_only` tier ready for the
  future Gmail-read agent — without inventing capabilities now.

**Alternatives considered**:
- *Binary danger (safe/dangerous).* Rejected: collapses `kv_append` and a future read-only Gmail
  grant into the same bucket; the spec's danger ordering (FR-004) wants read-only < local < external.
- *Numeric danger score.* Rejected: over-engineered (Constitution I); ordered atoms suffice.
- *Read danger via `Connector.get/1`.* Rejected: bypasses runtime/test registry overrides and could
  disagree with what enforcement reads → FAITHFUL violation.

## R3 — Structured entries vs. direct string formatting

**Decision**: The render produces a list of typed `%AgentOS.CapabilityRender.Entry{}` (one per
grant) first, then a thin `format/1` turns entries into the inventory text. Totality and
faithfulness are asserted at the structured level; formatting is a deterministic presentation layer.

**Rationale**:
- TOTAL (FR-001) is cleanly testable as "entries count == grants count" without string parsing.
- Strong typing, no bare maps (Constitution V).
- A later plan (deploy consent screen) can reuse `entries/1` and apply its own formatting without
  re-deriving danger/phrases.

**Alternatives considered**:
- *Return a formatted string only.* Rejected: forces string-matching tests and blocks reuse by the
  future consent screen.

## R4 — Edge-case handling (totality vs. loud failure)

**Decision**:
- **Grant whose connector has no phrase-map entry** → render a deterministic fallback phrase that
  surfaces the generic capability name, still tagged with its registry-derived danger tier. Never
  dropped (FR-011, TOTAL). The connector still exists in the registry, so its danger is known.
- **Grant whose connector is absent from the registry at render time** → raise (loud failure,
  Constitution VI / FR-011). This should be unreachable because the manifest parser rejects unknown
  connectors at load, but the render must not silently omit or guess a danger level.
- **No grants** → an explicit "no capabilities granted" line, not a blank section.
- **Multiple grants for the same connector** → one entry per grant (no merge), each reflecting its
  own scope.
- **Equal-danger ordering** → stable: preserve manifest grant order; do not reorder.

**Rationale**: Totality is the silent-failure the principle exists to prevent; a missing phrase must
degrade visibly, while a missing *danger source* must fail loudly rather than mislead.

## R5 — Surface integration

**Decision**: In `AgentOS.Inventory.render/1`, replace the line
`GRANTS: #{inspect(manifest.grants)}` with the capability render's formatted output (a labelled
`CAPABILITIES:` block). `manifest.grants` is already in scope there.

**Rationale**: The standing inventory is the existing read-without-asking-the-agent surface
(Constitution VIII); this is the one place capabilities are shown to a human in this slice (FR-009).
No other surface is added (consent screen is a later plan).
