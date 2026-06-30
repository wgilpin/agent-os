# Feature Specification: Deterministic Capability Render

**Feature Branch**: `009-capability-render`
**Created**: 2026-06-30
**Status**: Draft
**Input**: User description: "Deterministic capability render — turn an agent's manifest grants into a faithful, total, danger-ranked, normie-readable view of what the agent is allowed to do (roadmap plan 04-01, Phase 4 Generation MVP; permission-visibility axis — the one principle with no flag, Constitution VIII Legibility)."

## Overview

When a human looks at what an agent is allowed to do, they currently see the raw grant
structures dumped into the standing inventory (`GRANTS: [%AgentOS.Manifest.Grant{...}]`).
A non-coder cannot read that, and — more dangerously — cannot tell a read-only capability
apart from one that sends data out of the system or spends money.

This feature adds a substrate-side component that reads an agent's manifest grants and the
substrate's connector capability registry and produces a human-readable rendering of what
the agent is allowed to do (e.g. a phrase per capability, with the send/egress capability
visibly marked as the riskier one). The render replaces the raw grant dump wherever
capabilities are shown to a human — in this slice, the existing standing inventory for the
running hand-written discovery agent.

This is the first plan of Phase 4 and part of the deploy-consent rail, but it is
generation-independent: it is built and proven on the EXISTING hand-written discovery agent,
with no generation, no orchestrator, and no LLM anywhere in it. The deploy-time consent
screen, blocking/approval flow, review modes, and the conformance auditor are LATER plans
(see Out of Scope).

The render MUST have four independently testable properties: **FAITHFUL** (it cannot drift
from what is actually granted), **TOTAL** (every grant is rendered; none is suppressed or
hidden), **DANGER-RANKED** (a mutating/egress capability does not look like a read-only one,
with the danger sourced from the registry — not the manifest author, not invented by the
render), and **NEVER LLM-WRITTEN** (a deterministic lookup from capability-type to phrase,
unable to be authored by a model).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A non-coder reads every capability and sees which are dangerous (Priority: P1)

A person who is not a programmer opens the standing inventory for the running discovery
agent. Instead of a raw grant dump, they see a plain-language list of everything the agent
is allowed to do — one readable phrase per granted capability — and the capability that can
send data out of the system (egress) is clearly distinguished from the one that only writes
to local state. They can decide, at a glance, whether they are comfortable with what the
agent can do.

**Why this priority**: This is the whole point of the feature — permission visibility, the
principle with no flag (Constitution VIII). Without it there is no consent view at all.
Totality and danger-ranking are both exercised by this single read. It is the acceptance
anchor.

**Independent Test**: Render the existing discovery agent's manifest and confirm the output
(a) contains a readable phrase for BOTH granted capabilities (`kv_append` and
`external_send`), and (b) marks the `external_send` capability as more dangerous than the
`kv_append` capability, using only registry-sourced danger metadata. No live dependencies
required.

**Acceptance Scenarios**:

1. **Given** the discovery agent's manifest (granting `kv_append` and `external_send`),
   **When** the standing inventory is rendered, **Then** the view contains one human-readable
   phrase for the `kv_append` capability and one for the `external_send` capability — neither
   is shown as a raw struct, connector identifier alone, or omitted.
2. **Given** the same render, **When** a non-coder reads it, **Then** the `external_send`
   capability (which mutates external state, requires a credential, costs money, and requires
   approval per the registry) is visually/semantically marked as higher danger than the
   `kv_append` capability (which mutates only local state, needs no credential, and is free).
3. **Given** an agent that holds a send/egress grant, **When** its capabilities are rendered,
   **Then** the send/egress grant is always present in the view and never silently omitted,
   summarised away, or collapsed into another capability.

---

### User Story 2 - The view cannot drift from what is enforced (Priority: P2)

A reviewer trusts the rendered view because it is computed mechanically from the same grant
fields the gate enforces. If a grant is added, removed, or changed in the manifest, the view
changes to match with no human re-authoring step. There is no path by which the displayed
capability and the enforced grant disagree.

**Why this priority**: Faithfulness is what makes the consent view trustworthy. A pretty but
drifting view is worse than the raw dump, because it lies. This guards the specific
silent-failure the principle exists to prevent: a grant the human believes is absent but is
actually enforced.

**Independent Test**: Render a manifest; change its grants (add a grant, remove a grant,
alter a grant's scope); re-render; confirm the output changed correspondingly in every case,
with no separately maintained description that could fall out of sync.

**Acceptance Scenarios**:

1. **Given** a manifest, **When** a grant is added to it and the view is re-rendered, **Then**
   a new phrase for that capability appears in the view.
2. **Given** a manifest, **When** a grant is removed and the view is re-rendered, **Then** the
   corresponding phrase disappears from the view.
3. **Given** a manifest, **When** a grant's author-set scope (recipients/methods) changes,
   **Then** the rendered view reflects the change (the scope shown tracks the grant).
4. **Given** any render, **When** the displayed capabilities are compared against the
   manifest's enforced grants, **Then** they correspond one-to-one — no capability is shown
   that is not granted, and no granted capability is missing.

---

### User Story 3 - The render is mechanical and unable to be model-authored (Priority: P3)

The rendered text is produced by a deterministic lookup from capability-type to phrase, with
danger derived from the registry's fixed danger metadata. No model writes the prose. The same
manifest always renders to the same view, and the render runs with no network, no model, and
no container.

**Why this priority**: This is the co-generation caveat. If a model authored both a grant and
its description, a misread would produce a grant and a description that agree with each other
and both mislead. The render must be mechanical so it cannot co-drift with a generated grant.
It is P3 only because it is a property of HOW the P1/P2 behaviour is achieved.

**Independent Test**: Run the render twice on the same manifest and confirm byte-identical
output (determinism). Confirm the render completes with no network/model/Docker access. Confirm
the danger classification for each capability is read from the registry, not from any manifest
field or generated text.

**Acceptance Scenarios**:

1. **Given** a fixed manifest and registry, **When** the view is rendered repeatedly, **Then**
   the output is identical every time.
2. **Given** a capability's danger ranking, **When** its source is traced, **Then** it derives
   only from the registry's danger metadata (mutates-external-state / requires-approval /
   credential / cost) for that generic capability name — never from the manifest author and
   never from model-authored text.
3. **Given** the render component, **When** it executes, **Then** it requires no network call,
   no model invocation, and no container — it reads only the manifest and the registry, both
   already substrate-side.

---

### Edge Cases

- **Granted connector absent from the phrase lookup**: If an agent holds a grant for a
  capability that has no human-readable phrase mapping, the capability MUST still be rendered
  (with a deterministic fallback that surfaces its generic capability name and registry danger
  metadata) and MUST carry its danger ranking — it is never silently dropped. Totality outranks
  prettiness.
- **Granted connector absent from the registry**: The manifest parser already rejects unknown
  connectors at load, but if a registry lookup nonetheless fails at render time, the render MUST
  fail loudly (surface the problem) rather than silently omit the grant or guess a danger level.
- **Agent with no grants**: The view renders an explicit "no capabilities granted" statement,
  not an empty/blank section that could be mistaken for "not rendered yet".
- **Multiple grants for the same connector** (e.g. two `external_send` grants with different
  scopes): Each grant renders as its own line/phrase reflecting its own scope; none is merged
  away.
- **Two capabilities at the same danger level**: Ranking remains stable and deterministic (no
  nondeterministic ordering between equal-danger capabilities).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001 (TOTAL)**: The render MUST emit exactly one human-readable capability entry for
  every grant in the agent's manifest — no grant is suppressed, summarised away, merged, or
  hidden. The count of rendered capability entries equals the count of manifest grants.
- **FR-002 (FAITHFUL)**: Each capability entry MUST be computed mechanically from the grant's
  own fields (its generic connector/capability name and its author-set scope) plus the
  registry's danger metadata — with no separately authored description that could fall out of
  sync. A change to the manifest grants MUST change the render correspondingly.
- **FR-003 (FAITHFUL)**: The render MUST reflect each grant's author-set scope constraints
  (recipients/methods) where present, so the human sees not just the capability type but its
  bounds; scope text tracks the grant.
- **FR-004 (DANGER-RANKED)**: Each capability entry MUST carry a danger ranking derived
  deterministically from the registry's danger metadata for that generic capability name —
  specifically whether it mutates external state, requires approval, requires a credential, and
  its per-action cost. A capability that sends data out / mutates external state / costs money /
  requires approval MUST rank as more dangerous than one that only writes local state, which in
  turn ranks above a read-only capability.
- **FR-005 (DANGER-RANKED)**: The danger ranking MUST be visually and/or semantically distinct
  in the rendered output, such that a non-coder can tell an egress/send capability apart from a
  read-only or local-only one without reading code. The `external_send` capability MUST be
  visibly distinguished from the `kv_append` capability in the discovery agent's render.
- **FR-006 (DANGER source-of-truth)**: The danger classification MUST be sourced ONLY from the
  substrate's connector capability registry, keyed by generic capability name. It MUST NOT be
  taken from the manifest author and MUST NOT be invented or inferred by the render itself.
- **FR-007 (NEVER LLM-WRITTEN)**: The capability phrase MUST be produced by a deterministic
  lookup from generic capability name to phrase. No model/LLM may author any part of the
  rendered text. The same manifest + registry MUST always produce identical output.
- **FR-008 (Agent-agnostic)**: The capability phrases MUST be looked up by generic capability
  name; no single agent's domain vocabulary may be hard-coded into the render. The render of a
  given capability is the same regardless of which agent holds the grant.
- **FR-009 (Surface)**: The render MUST replace the raw grant dump in the existing standing
  inventory for the running discovery agent, so the human reads the capability view where they
  already read what exists — without consulting the agent (Legibility).
- **FR-010 (No live dependencies)**: The render MUST read only the manifest and the connector
  registry (both already substrate-side) and MUST require no network, no model, and no
  container to produce its output.
- **FR-011 (Loud on gaps)**: A granted capability with no phrase mapping MUST still be rendered
  with a deterministic fallback and its danger ranking (never dropped); a registry lookup
  failure at render time MUST fail loudly rather than silently omit or guess.
- **FR-012 (Read-only scope)**: This feature only READS the manifest, grants, registry, and
  danger metadata. It MUST NOT modify the gate, the manifest schema, enforcement, the registry's
  danger metadata, or introduce any new connector, grant, or capability type.

### Key Entities

- **Grant**: An author-declared capability request in the manifest — a generic connector name
  plus optional author-set scope (recipients, methods). The unit that must be rendered (one per
  grant). Already exists; read-only here.
- **Connector capability (registry entry)**: The substrate's fixed record for a generic
  capability name — whether it mutates external state, whether it requires approval, which
  credential it needs, and its per-action cost. The authoritative source of danger. Already
  exists; read-only here.
- **Capability phrase mapping**: A deterministic, substrate-owned lookup from a generic
  capability name to a human-readable phrase. The mechanical, never-model-authored source of the
  readable text. New to this feature; not danger metadata.
- **Rendered capability view**: The human-readable output — one entry per grant, each with its
  phrase, its author-set scope (where present), and its registry-derived danger ranking,
  surfaced in the standing inventory.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001 (TOTAL)**: For the discovery agent and any test manifest, 100% of manifest grants
  appear as a distinct readable capability entry in the rendered view — 0 omissions, 0 silent
  merges. A held send/egress grant is never absent from the view.
- **SC-002 (FAITHFUL)**: For every change applied to a manifest's grants (add / remove /
  rescope), the rendered view changes to match in 100% of cases, with no separately maintained
  description left to drift.
- **SC-003 (DANGER-RANKED)**: A non-coder, shown the discovery agent's rendered view with no
  code access, can correctly identify which capability can send data out of the system (the
  egress one) — distinguishing `external_send` from `kv_append` — in 100% of renders.
- **SC-004 (NEVER LLM-WRITTEN / deterministic)**: Rendering the same manifest and registry
  repeatedly produces byte-identical output every time, and the render completes with no
  network, model, or container access.
- **SC-005 (Agent-agnostic)**: The same capability renders to the same phrase and danger rank
  regardless of which agent holds it; no agent's domain vocabulary appears hard-coded in the
  render component.

## Assumptions

- The acceptance anchor is the EXISTING discovery agent, whose two grants are `kv_append`
  (mutating local state, no credential, free) and `external_send` (egress, requires approval,
  `outbound_token` credential, costs 2000µ$). The Gmail "READ YOUR GMAIL" / "SEND EMAILS FROM
  YOUR GMAIL" wording in the roadmap is illustrative of a FUTURE agent that does not yet exist;
  on the existing agent the proven distinction is local-mutation (`kv_append`, lower danger) vs
  egress/send (`external_send`, higher danger). No new connector, grant, or capability is added.
- The connector capability registry already carries the danger metadata needed
  (mutates-external-state, requires-approval, credential, cost). This feature reads that
  metadata unchanged; it does not add to or alter the registry's danger metadata.
- The capability-name → phrase lookup is a new, deterministic, substrate-owned mapping. It is
  not danger metadata, so introducing it does not violate the "no change to the registry's
  danger metadata" scope boundary. Where exactly it is stored is an implementation detail for
  the plan.
- The render surfaces on the existing standing inventory (`AgentOS.Inventory.render/1`),
  replacing the current raw `inspect(manifest.grants)` line. Other surfaces (deploy consent
  screen) are out of scope and arrive in later plans that may reuse this render.
- Danger ordering is, from lowest to highest: read-only (non-mutating) < local-only mutation
  (mutating, no credential, no cost, no approval) < external/egress (mutates external state
  and/or requires a credential and/or costs money and/or requires approval). The exact tier
  labels and visual treatment are a plan-level detail, constrained by FR-004/FR-005.
- "Non-coder readable" is validated by inspection of the phrasing (plain language, no struct
  syntax, no connector identifiers standing alone) rather than by a live user study, consistent
  with the no-live-dependencies constraint.

## Out of Scope

- Review modes and the deterministic envelope predicate (`--always-review` /
  `--review-if-risky` / `--dangerously-skip-review`) — plan 04-03.
- The deploy flow, human-approval/blocking, and deploy provenance — plan 04-09.
- The conformance auditor (post-deploy run-trace comparison) — plan 04-02.
- All of generation (elicit spec / write manifest / write judge / write agent /
  security-review) — plans 04-04…08.
- Any change to the gate, the manifest schema, the connector registry's danger metadata, or
  enforcement — this plan only READS those and renders them.
- Any new connector, grant, or capability type.
- A standalone deploy-time consent screen UI — this slice surfaces the render only in the
  existing standing inventory.
