# Feature Specification: Stage 2 Write the Manifest (write-manifest)

**Feature Branch**: `013-write-manifest`  
**Created**: 2026-06-30  
**Status**: Draft  
**Input**: User description: "Stage 2 of the v3 six-stage generation pipeline — WRITE THE MANIFEST. Deterministically emit a manifest from the human-confirmed ELICITED SPEC artifact produced by Stage 1 (04-04). The manifest — purpose + capability grant + boundary contract + spend — is THE safety artifact (the manifest, not the judge). This stage does NOT talk to the user, does NOT write the judge, the agent body, or any agent code; it produces the machine-written manifest and the consent view the human signs off. The input is the strongly-typed ElicitedSpec (AgentOS.ElicitedSpec) with confirmed: true — and that is the SOLE input. The output is a manifest conforming to the EXISTING manifest schema, such that the SAME deterministic gate that enforces hand-written manifests (v2) enforces this machine-emitted one with no special-casing and no new enforcement path."

## Overview

Stage 2 is the second stop in the v3 generation pipeline. It takes the single artifact
Stage 1 produced — a strongly-typed, human-confirmed `ElicitedSpec` — and **mechanically
projects** it into a manifest that conforms to the existing v2 manifest schema. The manifest
it emits is the project's *safety artifact*: purpose + capability grant + boundary contract +
spend, declared once and enforced at runtime by the same deterministic gate that already
enforces hand-written manifests.

The defining constraint is that this projection is a **pure, deterministic function**, not an
LLM regeneration. The human confirmed an intent in Stage 1; Stage 2 renders that exact intent
into manifest form without a model re-deriving, widening, or "filling in" any field. This is
what makes the manifest trustworthy as the thing the human signed off on — and it is the whole
point of Phase 4 to point a generator at v2 enforcement that is already proven airtight, rather
than inventing a parallel safety rail.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Project a confirmed spec into an enforceable manifest (Priority: P1)

The pipeline hands Stage 2 a confirmed `ElicitedSpec`. Stage 2 mechanically maps each field of
that spec onto the corresponding manifest field — purpose, the capability grants, the boundary
contract (recipients/methods/scope), and the spend cap — and emits a manifest that conforms to
the existing manifest schema. The exact same gate that enforces a hand-written manifest then
loads and enforces this machine-emitted one, with no special-casing and no new code path.

**Why this priority**: P1. This is the core purpose of Stage 2. Without a faithful, schema-valid
manifest there is nothing for the downstream stages (judge, agent body, security review, deploy)
to be checked against, and nothing for the runtime gate to enforce.

**Independent Test**: Construct a confirmed `ElicitedSpec` in a test, run the projection, and
assert the emitted manifest (a) parses and validates under the existing manifest loader/schema,
(b) is byte-for-byte deterministic across repeated runs from the same input, and (c) is accepted
and enforced by the existing gate with no manifest-source-specific branch.

**Acceptance Scenarios**:

1. **Given** a confirmed `ElicitedSpec` with a purpose, capabilities, boundaries, and spend
   limits, **When** Stage 2 runs the projection, **Then** it produces a manifest whose `purpose`,
   `grants`, and `spend` faithfully represent the spec, and which validates under the existing
   manifest schema.
2. **Given** the emitted manifest, **When** it is loaded by the same deterministic gate used for
   hand-written (v2) manifests, **Then** the gate enforces it identically, with no branch that
   distinguishes a machine-written manifest from a hand-written one.
3. **Given** the same confirmed `ElicitedSpec` projected twice, **When** the two outputs are
   compared, **Then** they are identical (the projection is a pure, deterministic function).

---

### User Story 2 - Reject an unconfirmed spec at the boundary (Priority: P1)

Stage 2 refuses to emit a manifest from any spec that is not explicitly confirmed. Because
`confirmed` defaults to `false` on the struct, an under-elicited or abandoned intent cannot
silently flow downstream into an enforceable artifact.

**Why this priority**: P1. The human confirmation in Stage 1 is the load-bearing step of the
whole co-generation safety argument. If Stage 2 could mint a manifest from an unconfirmed spec,
that argument breaks — an agent could be generated from an intent the human never agreed to.

**Independent Test**: Pass an `ElicitedSpec` with `confirmed: false` (and one with `confirmed`
unset, relying on the default) into Stage 2 and assert that no manifest is produced and a clear
rejection/error is returned.

**Acceptance Scenarios**:

1. **Given** an `ElicitedSpec` with `confirmed: false`, **When** Stage 2 is invoked, **Then** it
   produces no manifest and returns an explicit "spec not confirmed" rejection.
2. **Given** an `ElicitedSpec` where `confirmed` was never set (defaulting to `false`), **When**
   Stage 2 is invoked, **Then** it is rejected by the same structural guard — the guard is
   asserted at Stage 2's entry, not assumed from Stage 1.

---

### User Story 3 - Show the human the consent view of the finished manifest (Priority: P1)

After the manifest is emitted, Stage 2 renders a human-readable consent view **from the finished
manifest** by reusing the existing deterministic capability render (04-01). The view is the
danger-ranked, read-vs-send/egress phrasing of the actual grants. The human sees and confirms the
*artifact the gate will enforce* — closing the loop between "what I agreed to" and "what runs."

**Why this priority**: P1. Stage 1 confirmed an intent; this view confirms the *realized* manifest
that resulted from projecting that intent. Rendering from the finished manifest (rather than from
the spec) is precisely what 04-04 deferred to this stage, and it is what guarantees the human is
looking at the enforced grant, not a paraphrase of it.

**Independent Test**: Emit a manifest from a confirmed spec, render the consent view via the
existing capability render, and assert the view is generated from the manifest's grants (not the
spec) and that it is faithful and total — every emitted grant appears in the view, danger-ranked.

**Acceptance Scenarios**:

1. **Given** an emitted manifest, **When** the consent view is rendered, **Then** it is produced
   by the existing deterministic capability render reading the manifest's grants, with no
   LLM-written phrasing.
2. **Given** a manifest containing a send/egress-capable grant, **When** the consent view is
   rendered, **Then** that grant is surfaced with its danger-ranked, read-vs-send phrasing.
3. **Given** the rendered consent view, **When** the human reviews it, **Then** the grants it
   describes are exactly the grants the gate will enforce — the view cannot drift from the manifest.

---

### User Story 4 - Preserve minimisation; surface under-specification as an error (Priority: P2)

The smallest grant footprint won during elicitation is carried through **unchanged**. Stage 2 may
not add a capability, connector, egress domain, or target location, nor raise a spend cap, beyond
what the confirmed spec contains. If the spec under-specifies a *grant-bearing* field that the
manifest schema requires, Stage 2 surfaces that as an explicit error (a Stage-1 elicitation
failure) rather than guessing or widening — it has no conversation surface with which to ask.

**Why this priority**: P2. Minimisation is the core of the safety posture (Simplicity First,
Explicit Scope Control). A projection that quietly widened scope, or that papered over a missing
required field with a guess, would make the manifest an unfaithful representation of the confirmed
intent.

**Independent Test**: Project a spec and assert the manifest's capability/connector/egress/target
set is a faithful, non-superset image of the spec's. Separately, pass a spec that omits a
grant-bearing required manifest field and assert Stage 2 errors rather than emitting a widened or
guessed manifest.

**Acceptance Scenarios**:

1. **Given** a confirmed spec listing exactly capabilities {A, B}, **When** Stage 2 projects it,
   **Then** the manifest grants exactly {A, B} and no others — no capability, connector, egress
   domain, or target location is added.
2. **Given** a confirmed spec with a spend cap of N, **When** Stage 2 projects it, **Then** the
   manifest's spend cap is exactly the projection of N and is never raised above it.
3. **Given** a confirmed spec that omits a grant-bearing field the manifest schema requires,
   **When** Stage 2 is invoked, **Then** it returns an explicit under-specification error and
   produces no manifest — it does not guess a value and does not ask the user.

---

### User Story 5 - Keep the machine-written manifest invisible to the agent (Priority: P3)

The emitted manifest goes through the same invisibility discipline as a hand-written one: the
synthesised agent must never be able to read its own manifest, caps, prices, or usage, regardless
of the fact that a machine wrote the manifest. Stage 2 introduces no path by which the manifest
could leak across the port boundary to the agent.

**Why this priority**: P3. This invariant is owned and fully re-verified end-to-end later (04-09);
here the requirement is purely negative — Stage 2 must not *introduce* a leak. The manifest is a
substrate-only, privileged-read artifact for the gate.

**Independent Test**: Inspect Stage 2's outputs and side effects and assert the manifest is only
ever written to the substrate-side location the gate reads, and is never placed where it would
cross the port boundary into the agent container.

**Acceptance Scenarios**:

1. **Given** Stage 2 emits a manifest, **When** its outputs are inspected, **Then** the manifest
   lives only in the substrate-side, gate-readable location and is not handed to or readable by the
   agent.
2. **Given** the projection runs, **When** its effects are traced, **Then** no new code path exposes
   the manifest, caps, prices, or usage to the agent workload.

---

### Edge Cases

- **Unconfirmed or default-unset spec**: rejected at the entry guard (US2) — no manifest, explicit
  rejection.
- **Grant-bearing required field missing** (e.g., a capability with no resolvable connector, or an
  empty/absent capability set where the schema requires grants): surfaced as an under-specification
  error (US4), not guessed.
- **Capability that does not resolve to a known connector**: the projection fails loudly rather than
  emitting an unknown/unenforceable grant (the existing manifest loader and capability render both
  already fail loudly on unknown connectors; Stage 2 must not bypass that).
- **Spec spend cap of zero or a value below the deterministic review-envelope threshold**: faithfully
  projected as-is; Stage 2 does not adjust it. (Stage 2 only emits the spend field; the
  envelope/review-mode predicate that *reads* it is the 04-03 rail and is out of scope here.)
- **Non-grant structural manifest fields absent from the spec** (owner, supervision, spend window,
  spend breach action): the spec does not carry these by design; Stage 2 fills them with fixed,
  deterministic, strictest-available constants that can only narrow, never widen, the footprint —
  not LLM-derived values and not a widening of any grant (see Assumptions).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Stage 2 MUST accept a single input: a strongly-typed `ElicitedSpec`. It MUST NOT
  consult any other source (no conversation transcript, no model, no external lookup) to determine
  manifest contents.
- **FR-002**: The `ElicitedSpec` → manifest mapping MUST be a pure, deterministic function: the same
  input always yields an identical manifest, and no LLM/model participates in deriving, widening, or
  filling any manifest field.
- **FR-003**: Stage 2 MUST emit a manifest conforming to the EXISTING manifest schema, such that the
  existing manifest loader parses and validates it with no schema change.
- **FR-004**: The emitted manifest MUST be enforced by the SAME deterministic gate that enforces
  hand-written (v2) manifests, with no special-casing, no manifest-provenance branch, and no new
  enforcement path.
- **FR-005**: Stage 2 MUST reject any `ElicitedSpec` whose `confirmed` flag is not `true`, producing
  no manifest and returning an explicit rejection. This guard MUST be asserted at Stage 2's own entry
  (relying on the struct default of `confirmed: false`), not assumed to have been enforced upstream.
- **FR-006**: Stage 2 MUST faithfully project the spec's purpose into the manifest's purpose without
  rephrasing or regenerating it via a model.
- **FR-007**: Stage 2 MUST project the spec's capabilities into manifest grants such that the set of
  capabilities/connectors granted is exactly the spec's set — never a superset. No capability or
  connector may be added.
- **FR-008**: Stage 2 MUST carry the spec's boundary contract (egress domains, target locations) into
  the manifest's grant scope constraints (e.g., recipients/methods) without widening — never adding
  an egress domain or target location absent from the spec.
- **FR-009**: Stage 2 MUST project the spec's spend limit into the manifest's spend cap without
  raising it. The spend cap MUST never exceed the projection of the spec's limit.
- **FR-010**: If the spec under-specifies a grant-bearing field that the manifest schema requires,
  Stage 2 MUST surface this as an explicit error and emit no manifest. It MUST NOT resolve the
  ambiguity by guessing a value, and MUST NOT ask the user (it has no conversation surface).
- **FR-011**: For required manifest fields that the `ElicitedSpec` does not carry and that are NOT
  grant-bearing (owner, supervision, spend window, spend breach action), Stage 2 MUST populate them
  from fixed, deterministic constants chosen as the strictest available value, such that they can
  only narrow and never widen the agent's footprint.
- **FR-012**: After emitting the manifest, Stage 2 MUST render a human-readable consent view FROM the
  emitted manifest by reusing the existing deterministic capability render (04-01). The view MUST be
  generated from the manifest's grants, MUST be faithful and total (every grant represented), and
  MUST contain no LLM-written phrasing.
- **FR-013**: The consent view MUST describe exactly the grants the gate will enforce — it MUST NOT
  be able to drift from the emitted manifest.
- **FR-014**: Stage 2 MUST NOT introduce any path by which the manifest, its caps, prices, or usage
  become readable by the synthesised agent. The manifest remains a substrate-only, gate-readable
  artifact and MUST NOT cross the port boundary into the agent container.
- **FR-015**: Stage 2 MUST NOT confer authority and MUST NOT act as a firewall. The manifest it emits
  is a declaration only; runtime enforcement at the deterministic gate still validates every action
  against it regardless of how the manifest was produced.
- **FR-016**: Stage 2 MUST NOT perform any work belonging to other stages: it does not re-elicit
  (04-04), write the judge (04-06), generate the agent body (04-07), run security review (04-08),
  deploy (04-09), or compute the envelope/review-mode predicate (04-03). It only emits the manifest
  fields the predicate later reads.

### Key Entities

- **ElicitedSpec (input)**: The strongly-typed, human-confirmed output of Stage 1. Carries
  `purpose`, `capabilities` (allowlist), `boundaries` (egress domains, target locations),
  `spend_limits` (dollar cap, token limit), and a `confirmed` flag (default `false`). This is the
  SOLE input to Stage 2.
- **Manifest (output)**: An artifact conforming to the existing v2 manifest schema —
  `purpose`, `grants` (each a connector with optional recipients/methods scope), `spend`
  (cap/window/breach action), `owner`, `supervision`, and optional `triggers`/`mounts`. This is the
  safety artifact the gate enforces.
- **Grant**: A single capability grant within the manifest — a connector plus author-controlled
  scope constraints (recipients, methods). The image of one or more spec capabilities + boundaries.
- **Spend**: The manifest's spend constraint — cap (in the gate's existing units), window, and
  breach action. The image of the spec's spend limit.
- **Consent View**: The deterministic, danger-ranked, normie-readable render of the manifest's
  grants (produced by the 04-01 capability render), shown to the human as the final sign-off on the
  artifact the gate will enforce.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of manifests emitted from a confirmed spec parse and validate under the existing
  manifest schema with no schema modification.
- **SC-002**: The same confirmed spec projected any number of times yields byte-for-byte identical
  manifests (zero variance), confirming a pure deterministic projection.
- **SC-003**: A manifest emitted by Stage 2 is enforced by the existing gate with zero new or
  modified enforcement code paths and zero branches keyed on manifest provenance.
- **SC-004**: 100% of specs with `confirmed` not equal to `true` (including the default-unset case)
  are rejected with no manifest produced.
- **SC-005**: For every emitted manifest, the granted capability/connector/egress/target set is a
  subset-or-equal of the spec's — never a superset (no scope widening across any test input), and
  the spend cap is never above the projection of the spec's limit.
- **SC-006**: Every grant present in an emitted manifest appears in the consent view (100% coverage),
  and the consent view is generated entirely by the deterministic render with no model-authored text.
- **SC-007**: A spec missing a grant-bearing required field results in an explicit error and no
  emitted manifest in 100% of such cases (no silent guessing, no widening).
- **SC-008**: No Stage 2 output or side effect places the manifest where the agent workload can read
  it; the manifest is written only to the substrate-side, gate-readable location.

## Assumptions

- **Spend cap units (resolved from the codebase)**: The existing manifest `spend.cap` is denominated
  in **micro-dollars** (per `provisioner.ex` — "default 100_000 micro-dollars / $0.10" — and
  `inventory.ex`, which formats `spend.cap` as dollars). Therefore Stage 2 projects the spec's
  `spend_limits.dollar_cap` into `spend.cap` (dollars → micro-dollars). The spec's `token_limit` has
  no corresponding field in the existing manifest schema; since Stage 2 emits only the existing
  schema, the token limit is not projected into the v2 manifest here (it remains a Stage-1 /
  elicitation-level concern). This is documented as an assumption rather than asked because the unit
  is determinable from the code; if the intended mapping differs, it is a one-line projection change.
- **Non-grant structural defaults**: `owner`, `supervision`, `spend.window`, and `spend.on_breach`
  are required by the manifest but are not carried by the `ElicitedSpec`. Because they are not
  grant-bearing and cannot widen the footprint, Stage 2 supplies fixed deterministic constants set to
  the strictest available value (e.g., `owner: human`, the strictest supervision policy, `window:
  daily`, `on_breach: kill` — matching the existing hand-written manifest convention). Treating these
  as under-specification *errors* would make Stage 2 incapable of ever emitting a manifest, since the
  spec structurally cannot supply them; treating them as strictest-constants preserves minimisation.
- **Triggers / mounts**: The `ElicitedSpec` does not carry triggers or mounts and the manifest treats
  both as optional (defaulting to empty). Stage 2 emits them empty for the MVP; populating triggers is
  not part of this stage.
- **Boundary-to-grant association**: The spec's global boundary contract (egress domains, target
  locations) maps onto per-grant scope constraints (recipients/methods). The exact association rule is
  an implementation/plan concern; the requirement at this level is only that the mapping is
  deterministic and never widens beyond the spec's declared boundaries.
- **Consent-view surface**: Rendering the consent view reuses the existing `AgentOS.CapabilityRender`
  unchanged. Stage 2 does not author new phrasing; unknown connectors fail loudly as they already do.
- **No user interaction**: Stage 2 has no conversation surface. The "human signs off" step presents
  the already-rendered consent view; Stage 2 itself does not elicit, prompt, or re-ask.

## Out of Scope

- The elicitation conversation itself (04-04, done) — Stage 2 consumes its artifact and does not
  re-elicit.
- Judge synthesis (04-06), novel agent-body generation (04-07), security review (04-08), and
  deploy-on-green (04-09).
- The envelope / review-mode predicate (04-03) — Stage 2 only emits the manifest fields that predicate
  later reads; it does not compute review eligibility.
- Full end-to-end re-verification of the manifest-not-readable-by-agent invariant for a
  machine-written manifest (04-09) — here the obligation is only the negative one: introduce no leak.
- Any change to the manifest schema or to the deterministic gate's enforcement logic.

## References

- Roadmap plan 04-05 (Phase 4 Generation MVP) — `.planning/ROADMAP.md`
- REQ-gen-manifest (#NXpM) — `.planning/REQUIREMENTS.md`
- Phase-4 success criterion 1: "the OS questions the user until KISS-clear, then emits a
  human-readable manifest — and that manifest, not the judge, is the safety artifact"
- Design doc `agent-os-design.md`: :105 (Stage 2), :116 (co-generation caveat), :28 + :151 (manifest
  as single source of truth / consent phrasing), :196 + :221 (generator points at airtight v2
  enforcement), :204 (manifest-not-readable invariant), :141 (confers no authority / not a firewall)
- Constitution I (Simplicity First), II (Explicit Scope Control), III (Manifest Invisibility),
  V, X, XI, XII
- Existing modules: `lib/agent_os/manifest.ex`, `lib/agent_os/manifest/grant.ex`,
  `lib/agent_os/manifest/spend.ex`, `lib/agent_os/capability_render.ex`,
  `lib/agent_os/elicitation.ex` (`AgentOS.ElicitedSpec`), example manifest `manifests/discovery.md`
