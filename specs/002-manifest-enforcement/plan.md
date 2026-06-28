# Implementation Plan: Manifest Enforcement (v2)

**Branch**: `002-manifest-enforcement` | **Date**: 2026-06-28 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/002-manifest-enforcement/spec.md`

## Summary

Promote the manifest from advisory documentation to the **enforced contract**. A new
deterministic gate (`AgentOS.Gate`) runs in the BEAM control plane, in front of the existing
effector chokepoint, and validates every agent-proposed action against two sources: the
manifest's enumerated **grants** (which connector this agent may use, scoped to recipients and
methods) and the substrate's **connector capability registry** (which fixes each connector's
intrinsic danger — `mutating?`, `requires_approval?`, `credential`, `cost` — so a manifest
author cannot downgrade a dangerous capability). The manifest never crosses the port boundary
(already true — only `{state, items}` is sent), so the agent cannot read the contract it is
bound by. A `CredentialProxy` holds capabilities and injects a credential at the chokepoint
at action time, so no LLM-running component ever holds a mutating credential — demonstrated
against a mock credentialed connector (no live dependency). Spend is `{cap, window,
on_breach}` with per-action costs summed over a fixed window, metered at the chokepoint; a
breach fires a real `kill` that ends the run **without** triggering restart-once-and-alert.
Event- and message-triggers arrive as in-BEAM messages; approval is an event-trigger with
park-and-resume semantics. The acceptance bar is **world B**: an adversarial stub agent that
proposes an out-of-scope recipient, an over-cap spend, and an ungranted method is physically
blocked at the gate, proven by test.

This phase builds only enforcement on hand-authored manifests. No agent generation, no
LLM-authored manifests, no security-review or conformance-auditor (constitution XII).

## Technical Context

**Language/Version**: Elixir ~> 1.20 (control plane) · Python 3.11 (agent stub, `uv`)
**Primary Dependencies**: existing only — YamlElixir (manifest parse), Jason (boundary JSON),
Erlang Ports + Docker (Phase 2 boundary). No new Elixir or Python deps.
**Storage**: term-file via single-writer `StateStore` (spend ledger + pending approvals are new
mounts) + git-backed markdown run-log. No external DB.
**Testing**: ExUnit (gate, spend meter, manifest parser, credential proxy, triggers — pure
units test-first) · pytest (adversarial stub agent contract) · `:docker`-tagged integration
test for the full-stack world-B proof. No live LLM, no live external service (Constitution IV).
**Target Platform**: Linux/macOS host with Docker available (unchanged from Phase 2).
**Project Type**: Single project — BEAM control plane + Python agent workload across a port
boundary (unchanged).
**Performance Goals**: Not latency-sensitive (one daily run + ad-hoc event/message runs). The
gate is an in-process deterministic check; per-action validation is O(grants).
**Constraints**: Manifest constraints MUST NOT cross the port boundary or be mounted into the
container; no mutating credential in the agent's env or boundary payload; a breach kill is an
intentional terminal state, never an abnormal exit.
**Scale/Scope**: One agent, one manifest, one container per invocation. Concurrent multi-agent
enforcement is out of scope.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Simplicity First | PASS | Gate extends the existing `OutputCheck` type-membership check; spend ledger and pending-approvals reuse `StateStore` mounts rather than a new persistence layer; triggers are plain in-BEAM messages (no web/CLI surface). The one addition is a mock credentialed connector — the minimum needed to make the credential proxy demonstrable. |
| II. Explicit Scope Control | PASS | Exactly the Phase 3 roadmap set (gate, manifest constraints, credential proxy, spend/kill, triggers, world-B). No generation, no LLM-authored manifests, no review/auditor agents. |
| III. Test-Driven Backend | PASS | Gate, spend meter, manifest constraints parser, credential proxy, trigger routing are pure/deterministic and written red→green→refactor. |
| IV. No Live Dependencies in Tests | PASS | Adversarial + happy-path runs use the deterministic stub agent; the credentialed connector is a mock sink. No LLM, no live API in any test. |
| V. Strong Typing, No Bare Maps | PASS | New `Grant`, `Constraints`, `Spend`, `GateDecision` structs + typespecs; Python contract via Pydantic. No bare maps for the new entities. |
| VI. Loud Failures | PASS | Every gate rejection logs the failing constraint; every breach logs the kill; malformed constraints fail provisioning loudly. No silent denial. |
| VII. Self-Documenting Comments | PASS | Each new module/function gets a purpose doc; the manifest schema change is documented in a contract. |
| VIII. Legibility | PASS | Gate decisions, spend, and breach kills are written to the run-log/inventory; spend is per-agent inspectable WITHOUT asking the agent. |
| IX. Substrate Owns State & Lifecycle (agent-agnostic) | PASS (improved) | Spend ledger + pending approvals owned by `StateStore`; the gate reads recipient/method scoping FROM the manifest. Connectors in the registry are **generic capabilities** (`kv_append`, `external_send`), not agent verbs — this de-leaks the current `Effector` which hard-codes `"record_signal"`/`"append_digest"`. No agent vocabulary enters `lib/agent_os/`. |
| X. No Ambient Authority | PASS | The manifest grants are the agent's entire power and are privileged-read for the gate only; the manifest does not cross the boundary nor mount into the container. |
| XI. The Gate Is the Only Firewall | PASS | This phase *is* the gate. The `CredentialProxy` guarantees no LLM-running component holds a mutating credential; the privileged write is deterministic, post-gate. |
| XII. Enforcement Precedes Generation | PASS | Enforcement is built here, on hand-authored manifests, before any generation (v3). Ordering honored. |

**No unjustified violations.** One justified addition (mock credentialed connector) is tracked
in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/002-manifest-enforcement/
├── plan.md                  # This file
├── research.md              # Phase 0 — enforcement design decisions
├── data-model.md            # Phase 1 — entities & validation rules
├── quickstart.md            # Phase 1 — drive a gated run, trigger, approval, breach, world-B
├── contracts/
│   ├── manifest-schema.md   # v2 manifest: grants{connector,recipients,methods} + spend + triggers
│   ├── connector-registry.md# Connector capability registry: per-connector intrinsic danger metadata
│   ├── gate.md              # Gate decision contract (proposed action → approve/reject + reason)
│   ├── triggers.md          # In-BEAM event/message trigger + approval-as-event contract
│   └── boundary.md          # Confirms the manifest does NOT cross the port boundary
├── checklists/
│   └── requirements.md      # Spec quality checklist (from /speckit-specify)
└── tasks.md                 # Phase 2 — created by /speckit-tasks, NOT here
```

### Source Code (repository root)

```text
lib/agent_os/
├── gate.ex                  # NEW — deterministic gate: action vs grant scope + connector registry + spend
├── manifest.ex              # MODIFIED — parse grants{connector,recipients,methods}, spend{window,on_breach}, trigger types
├── manifest/
│   ├── grant.ex             # NEW — Grant struct (connector, recipients, methods) — scope only
│   └── spend.ex             # NEW — Spend struct ({cap, window, on_breach})
├── connector.ex             # NEW — Connector behaviour + capability registry: per-connector {mutating?, requires_approval?, credential, cost}; generic names; a mock credentialed sink
├── spend_meter.ex           # NEW — fixed-window per-agent spend accounting (cost from registry; StateStore ledger)
├── credential_proxy.ex      # NEW — holds caps keyed by registry credential id; injects at the chokepoint at action time
├── trigger_bus.ex           # NEW — accepts in-BEAM event/message triggers; routes approval events
├── effector.ex              # MODIFIED — dispatch by connector generically (de-leak); gate-approved only; inject credential at chokepoint
├── run_worker.ex            # MODIFIED — Gate replaces bare OutputCheck; park-and-resume; breach → non-error terminal
├── provisioner.ex           # MODIFIED — provision from enforced manifest; fail loud on malformed constraints
├── scheduler.ex             # MODIFIED — time trigger now one trigger source among event/message
└── output_check.ex          # MODIFIED/folded — shape check retained; type+scope checks move into Gate

manifests/
└── discovery.md             # MODIFIED — grants as {connector, recipients, methods}; spend{window,on_breach}; event/message trigger

agents/discovery/
├── main.py                  # unchanged behaviour (still a deterministic stub)
└── adversarial_stub.py      # NEW — hostile variant: proposes out-of-scope recipient / over-cap / ungranted method

config/
└── config.exs              # MODIFIED — spend window/on_breach defaults; pending-approvals + spend mount names

test/agent_os/
├── gate_test.exs            # NEW — grant/constraint/spend validation (pure, incl. all reject categories)
├── spend_meter_test.exs     # NEW — fixed-window accounting, cap boundary, reset
├── credential_proxy_test.exs# NEW — injection at chokepoint; credential absent from agent env/payload
├── manifest_test.exs        # NEW — constraints/spend/trigger parse + malformed → loud failure
├── trigger_bus_test.exs     # NEW — event/message fire exactly one run; approval park-and-resume
├── effector_test.exs        # MODIFIED — only gate-approved actions execute; credential injected
└── world_b_test.exs         # NEW (:docker) — adversarial stub blocked in all three categories, effector never runs
```

**Structure Decision**: Single project, extending the Phase 1/2 layout. The integration seam is
the effector chokepoint: today `run_worker` does `OutputCheck.validate → Effector.act_all`. The
gate inserts there — `Gate.evaluate(action, manifest, registry, spend) → {:approve | :reject |
:needs_approval | :breach}` — and the effector executes only approved actions, dispatching by
the grant's connector (generic, de-leaked) with the credential proxy injecting at that exact
point. The manifest stays host-side (it already never crosses the boundary), so US2 is
preserved by construction and verified by a contract test rather than newly built.

## Complexity Tracking

| Addition | Why Needed | Simpler Alternative Rejected Because |
|----------|------------|--------------------------------------|
| Connector capability registry (`connector.ex` — behaviour + per-connector intrinsic metadata) | Approval/credential/cost must be a fixed property of a capability, not an author-set manifest field, or a (future machine) manifest author could grant a dangerous connector with `requires_approval: false` and defeat the gate. The registry makes danger non-negotiable by the author and de-leaks the Effector's hard-coded action names (Principle IX). | A per-grant `requires_approval` flag (original plan) is unsound: it lets the author downgrade danger — exactly what v2 must prevent before v3 generation. The registry is a small behaviour + metadata map, and it *removes* fields from the grant, so net surface is modest. |
| Mock credentialed connector (a registry entry, e.g. `external_send`, backed by a mock sink) | The current actions are local `StateStore` writes with no credential, so the credential proxy has nothing to inject and FR-008/FR-009 cannot be demonstrated. A registry connector that *requires* an injected credential makes the proxy real. | Asserting "no credential" against actions that never needed one proves nothing — the credential boundary needs at least one credentialed path. A mock sink keeps it deterministic (Principle IV). |

## Phase 0 — Research

See [research.md](./research.md). Resolves: gate placement vs the existing `OutputCheck`;
manifest grant schema (scope) vs connector capability registry (intrinsic danger) and typed
parsing; how to keep the manifest off the boundary (verify, don't rebuild); credential-proxy
injection point and the mock connector; fixed-window
spend accounting + cap-boundary semantics; breach-kill that bypasses restart-once-and-alert;
in-BEAM trigger routing and approval park-and-resume; the world-B adversarial test strategy
(unit-level gate adversary + full-stack `:docker` adversarial stub).

## Phase 1 — Design & Contracts

- [data-model.md](./data-model.md) — Manifest, Grant, Constraints, Spend, ProposedAction,
  GateDecision, SpendLedger entry, PendingApproval, Trigger, Capability — with validation rules
  drawn from FR-001…FR-017.
- [contracts/manifest-schema.md](./contracts/manifest-schema.md) — the v2 manifest YAML: grants
  as `{connector, recipients, methods}` (scope only), spend `{cap, window, on_breach}`, and
  `event`/`message` trigger types.
- [contracts/connector-registry.md](./contracts/connector-registry.md) — the substrate's
  per-connector intrinsic metadata (`mutating?`, `requires_approval?`, `credential`, `cost`);
  generic connector names; author cannot downgrade danger.
- [contracts/gate.md](./contracts/gate.md) — the gate decision contract: the proposed-action
  shape it consumes and the `{:approve, grant} | {:reject, failing_constraint} | {:breach,
  :spend}` it returns, with default-deny.
- [contracts/triggers.md](./contracts/triggers.md) — the in-BEAM trigger messages and the
  approval-as-event park-and-resume protocol.
- [contracts/boundary.md](./contracts/boundary.md) — asserts the port-boundary payload remains
  `{state, items}` and an action schema; the manifest's grants/caps/constraints appear nowhere
  in it nor in the container mount set.
- [quickstart.md](./quickstart.md) — drive a gated run, fire an event/message trigger, drive an
  approval, trip a spend breach, and run the world-B adversarial test.

**Post-design Constitution re-check**: still PASS — the design keeps the substrate the sole
owner of state and lifecycle, reads all scoping from the manifest (agent-agnostic), keeps the
manifest off the boundary, and removes mutating credentials from every LLM-running component.
