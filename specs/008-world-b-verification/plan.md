# Implementation Plan: World-B Verification — the Gate Physically Prevents Every Manifest Breach

**Branch**: `008-world-b-verification` (work lands on `master` per the 002–007 convention) | **Date**: 2026-06-29 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/008-world-b-verification/spec.md`

## Summary

Prove — as the final plan of Phase 3 — that the deterministic gate is a **world-B** firewall: it
physically prevents every manifest breach *regardless of agent code*. This is verification / red-team
work, not new substrate capability. Phase 3 built the enforcement boundary across plans 03-01…03-05
(gate, manifest invisibility, credential proxy, dollar metering, trigger intake), each proven in its
own slice. 03-06 ties the slices into one **adversarial suite** that drives the worst possible agent
behaviour at every enforcement chokepoint and asserts the boundary held — reading the verdict from
**substrate-side evidence alone** (gate return value, run-log, standing inventory, broker/spend
ledger), never from the agent.

The load-bearing design decision (resolved in [research.md](./research.md)): a hostile agent's only
power is the **output it emits** — the proposed-action batch, the strings in its stdout, the web
content it ingests. "Regardless of agent code" is therefore verified by feeding the enforcement
chokepoints arbitrary hostile *inputs directly* (a hostile `ProposedAction` batch, an agent-originated
trigger/approval signal, a manifest-read attempt), not by running hostile containers. This keeps the
whole world-B assertion set **deterministic, network-free, model-free, and docker-free** (Constitution
IV), while the existing `@tag :docker` `isolation_test.exs` remains the separately-run *physical*
backstop for sandbox-enforced classes (network-none, read-only fs).

Expected production code change: **none**. This plan adds one consolidated verification suite plus
hostile fixtures. If any breach class is found *not* prevented, that is a genuine enforcement defect
against the originating Phase-3 plan (recorded and fixed there), not new scope here (FR-013).

## Technical Context

**Language/Version**: Elixir ~> 1.20 (control plane). No Python workload change — hostile agent
*behaviour* is simulated by feeding hostile output to the chokepoints, not by new agent code.
**Primary Dependencies**: existing only. The eight enforcement primitives under verification —
`Gate.evaluate/4` + `Gate.partition_batch/4` (returns `{:approve|:needs_approval, grant}` /
`{:reject, reason}` / `{:breach, :spend}`); `Effector.act/1` (the sole egress chokepoint);
`TriggerGateway.submit/1`,`submit_sync/2` (the only signal intake); `CredentialProxy.with_credential/2`
(credential never returned to a caller); `InferenceBroker.complete/4` (trustless metering, injected
`provider_fn`); `SpendLedger`; `RunWorker.build_payload/2` (manifest never crosses to the agent);
`RunLog.append/2`; `Inventory.render/1`. **No new Elixir or Python dependency, no new module, no
schema change** (unless a verified gap forces a defect fix).
**Storage**: existing single-writer `StateStore`s (`spend_ledger`, `pending_approvals`, `roster_trust`)
and the git-backed append-only `run_log.md`. The suite only *reads* this evidence; it writes nothing
persistent beyond the per-test tmp stores `TestHelper.start_mounts!/2` already provisions.
**Testing**: ExUnit, deterministic only. New `test/agent_os/world_b_test.exs` — one `describe` per
breach class (1–8) plus a combined/replay `describe` (9), each asserting prevention from substrate-side
evidence with injected `effector_fn` / `provider_fn` / `:now` so no real action, network, model, or
container is touched. By-construction classes carry an anti-vacuousness **positive control** (BC-3: a
gate-approved action *does* reach `effector_fn`; BC-8: the `with_credential/2` closure *does* receive a
usable secret) so a negative assertion cannot pass for the wrong reason (FR-011); describe 9 pins the
chaining/replay invariant (FR-015). Hostile fixtures
(a hostile `ProposedAction` batch builder; agent-originated trigger/approval signals; a manifest-read
probe) live in `test/fixtures/world_b/`. Default run excludes `:docker` (`test_helper.exs` already sets
`ExUnit.start(exclude: [:docker])`); the physical sandbox classes are covered by the existing
`@tag :docker` `isolation_test.exs`, referenced but not part of the deterministic world-B gate.
**Target Platform**: Linux/macOS host (unchanged). Control-plane-only; the port boundary is unchanged.
**Performance Goals**: N/A — a test suite. Each check is an O(actions) gate call plus a map/log read.
**Constraints**: Every verdict MUST derive from substrate-side evidence, never agent self-report
(FR-009, FR-012). By-construction classes (no agent channel to intake/manifest/credential) assert the
**absence of a reachable surface**, distinct from a runtime guard rejecting a reachable attempt
(FR-010). Deterministic, no live dependencies in any assertion (FR-014). The World-B bar is met only
when all eight classes are prevented; an unprevented class is a failing verification that blocks Phase
4 (FR-013, SC-011).
**Scale/Scope**: 8 breach classes, one consolidated suite (~8 `describe` blocks), a small fixture
module. No production `lib/agent_os/` change expected.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Simplicity First | PASS | Pure verification: one new test file + one small fixture module. No new dependency, module, store, or schema. The simplest thing that proves the bar is to feed hostile *output* to the existing chokepoints rather than build a hostile-container harness. |
| II. Explicit Scope Control | PASS | Exactly the spec: verify the eight breach classes built in 03-01…03-05. No new enforcement, trigger, connector, grant, or constraint. A discovered gap is a defect against its originating plan, not new scope here (FR-013). |
| III. Test-Driven Backend | PASS | This *is* backend verification. Each breach class is expressed as a failing-first assertion against the chokepoint, then shown green by the existing enforcement. No frontend/endpoint unit tests added. |
| IV. No Live Dependencies in Tests | PASS, central | The entire world-B assertion set is deterministic: injected `effector_fn`/`provider_fn`/`:now`, hostile signals constructed in-test, zero network, zero model, zero docker. The `@tag :docker` physical sandbox tests are excluded from the default gate and run separately. |
| V. Strong Typing, No Bare Maps | PASS | Fixtures build typed `ProposedAction` structs and typed signal variants; assertions read typed gate returns (`{:reject, reason}` etc.). Dialyzer clean. |
| VI. Loud Failures | PASS | The suite asserts the *distinct* substrate-side log/verdict each rejection emits (`:recipient_out_of_scope`, `:method_out_of_scope`, `{:breach, :spend}`, unknown-ref no-op); a silent drop would fail the test. |
| VII. Self-Documenting | PASS | Each `describe` carries a `@moduledoc`/comment naming the breach class, the invariant it verifies, and whether the verdict is *by construction* or *runtime*. |
| VIII. Legibility | PASS, strengthened | The whole plan exists to prove every prevention is readable from the run-log / inventory / ledger **without asking the agent** — Legibility verified end-to-end. |
| IX. Substrate Owns State & Lifecycle | PASS | Verification asserts substrate ownership; hostile fixtures are agent-agnostic (no single agent's vocabulary enters `lib/agent_os/`; fixtures live under `test/fixtures/`). |
| X. No Ambient Authority | PASS, central | Breach classes 1,2,5,6,7,8 directly verify "an agent cannot widen its own authority, read its policy, fire/approve itself, or hold a credential" — the seL4 capability claim made testable. |
| XI. Deterministic Gate Is the Only Firewall | PASS, central | The plan's whole purpose: prove the gate is the *only* firewall and no LLM/agent path crosses it. No new authority is granted anywhere. |
| XII. Enforcement Precedes Generation | PASS, gating | This is the final enforcement proof; meeting the World-B bar is the precondition that *unlocks* Phase 4. Nothing here touches v3 generation. |

**Result**: PASS. No violations; Complexity Tracking table omitted.

## Project Structure

### Documentation (this feature)

```text
specs/008-world-b-verification/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 — hostile-output-vs-hostile-container decision; by-construction vs
│                        #            runtime proof taxonomy; evidence sources; docker-layer boundary
├── data-model.md        # Phase 1 — the breach-class coverage matrix (8 classes → invariant →
│                        #            chokepoint → fixture → evidence source → existing/new test)
├── quickstart.md        # Phase 1 — run the world-B suite; read a verdict from substrate evidence
├── contracts/
│   └── world-b-verification.md   # the verification contract: per-class given/attempt/evidence/verdict,
│                                 #   and the aggregate "all-eight-prevented" World-B bar
└── checklists/
    └── requirements.md  # Spec quality checklist (from /speckit-specify)
```

### Source Code (repository root)

```text
test/agent_os/
└── world_b_test.exs            # NEW — the consolidated adversarial suite; one describe per breach class:
                                #   1 exceed-grants (hostile ProposedAction batch → {:reject, :unknown_action})
                                #   2 spoof recipient/method ({:reject, :recipient_out_of_scope|:method_out_of_scope})
                                #   3 exfiltrate / no-bypass (Effector is the sole egress; by construction)
                                #     + positive control: a gate-approved action DOES reach effector_fn (path live, not dead) [FR-011]
                                #   4 bust the cap (InferenceBroker.complete trustless-meter → {:breach, :spend} + kill)
                                #   5 forge a trigger (agent-originated signal never fires; by construction)
                                #   6 forge/self-grant approval (agent-originated approve never resolves; at-most-once)
                                #   7 read the manifest (build_payload carries no manifest; by construction)
                                #   8 hold a credential (CredentialProxy never returns the secret; by construction)
                                #     + positive control: the with_credential/2 closure DOES receive a usable secret (proxy works, so "never returned" isn't vacuous) [FR-011]
                                #   9 combined/replay (chaining grants no new power; replay accumulates no extra effect): a
                                #     chained attempt — self-approve a held action whose recipient is ALSO out-of-scope — is
                                #     stopped at the first boundary; a duplicate trigger/proposal yields no extra effect [FR-015]

test/fixtures/world_b/
└── hostile.ex                  # NEW — agent-agnostic hostile fixtures: hostile ProposedAction batch builder,
                                #        agent-originated trigger/approval signals, manifest-read probe

test/agent_os/isolation_test.exs   # UNCHANGED, referenced — @tag :docker physical backstop for the
                                   #   sandbox-enforced facets of classes 3/7/8 (network-none, read-only fs);
                                   #   run via `mix test --include docker`, NOT part of the deterministic gate

lib/agent_os/*                  # UNCHANGED expected — pure verification. Any edit here means a verified
                                #   breach (defect fix against its originating Phase-3 plan), surfaced per FR-013.
```

**Structure Decision**: Single project, control-plane-only, **verification-only**. One new ExUnit
suite (`test/agent_os/world_b_test.exs`) plus one agent-agnostic fixture module
(`test/fixtures/world_b/hostile.ex`). No new top-level directories, no production `lib/agent_os/`
change in the happy path. The deterministic world-B suite is the "v2 done" gate; the existing
`@tag :docker` `isolation_test.exs` is the physical sandbox layer, run separately.

## Complexity Tracking

> No Constitution violations. Section intentionally omitted.
