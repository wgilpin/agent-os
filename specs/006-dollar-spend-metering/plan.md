# Implementation Plan: Dollar Spend Metering via an Inference Chokepoint

**Branch**: `006-dollar-spend-metering` (work lands on `master`, per 002/003/004/005 convention) | **Date**: 2026-06-29 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/006-dollar-spend-metering/spec.md`

## Summary

Replace the **source** of the metered spend number with **real dollars**, reusing 005's
enforcement model (fixed-resetting per-agent window, `on_breach` kill + restart-exemption,
per-agent visibility) unchanged. The dominant cost term — LLM inference — is metered at a new
substrate-side **inference broker** that the agent must route its model calls through. The broker
holds the inference key via the 004 credential proxy (`:model_key`), calls the provider, reads the
provider-reported token usage as ground truth, converts to **integer micro-dollars** via a
per-model price table, and meters those dollars into the existing per-agent `spend_ledger`. Real
per-action dollar costs (the connector registry `cost`, re-denominated to micro-dollars) sum into
the **same** ledger entry against the **same** cap.

Five pieces of new/changed behaviour:

1. **Inference broker** — a new `AgentOS.InferenceBroker` that, per call: applies 005's
   `SpendLedger.current_entry` window reset; refuses the call if `spent >= cap` (fail-closed
   pre-check → breach); else looks up the model price (fail-closed if missing), calls the provider
   via `CredentialProxy.with_credential(:model_key, …)`, computes `dollars = in_tokens·in_price +
   out_tokens·out_price` in micro-dollars, persists `spent + dollars` to `spend_ledger`, and — if
   the new total reaches/crosses the cap — flags the run's spend breach. The provider call is an
   **injectable function** so tests use a canned mock (Constitution IV); no live LLM.
2. **Local HTTP routing + egress lock** — the broker is reachable by the sandboxed Python workload
   over a substrate-mounted **unix-domain socket** (container keeps `network: none`); the agent's
   LLM client is pointed at it. A per-run **broker token** (substrate-injected env var) identifies
   the agent server-side, so the untrusted agent cannot spoof another agent's identity, cap, or
   price. The agent sends only `{model, messages}` + token; it receives only the completion.
3. **Inference-only breach (zero-action runaway)** — `RunWorker` gains a pre-gate check: **after the
   agent run returns** (where it already reads `spend_ledger`, so `spent` now includes the inference
   dollars the broker metered *during* the run) and **before the gate**, if the windowed
   `spent >= cap` the run is killed and the whole batch dropped, **even with zero proposed actions** —
   the runaway-bill case 005 missed.
4. **One dollar budget, two sources** — inference dollars (broker, pre-action) and per-action
   dollars (gate cost summed by `RunWorker`, post-gate) both land in the one `spend_ledger` entry
   `spent`, checked against one cap. The registry `cost` values are re-denominated to micro-dollars.
5. **Dollar-denominated visibility** — 005's `Inventory` render already reports `spent / cap /
   window`; the only change is the unit (micro-dollars formatted as dollars). The render is reused.

Everything in 005's window/reset/kill/restart-exemption/visibility **model** is reused unchanged
(FR-017): the broker writes into the same store, the same `{:killed, :spend_breach}` signal and the
same `RunSupervisor` restart-exemption apply, and `SpendLedger.current_entry/3` is the single window
helper for both broker and run-worker.

## Technical Context

**Language/Version**: Elixir ~> 1.20 (control plane) + a thin change to the Python workload
(`agents/discovery`) to route inference through the broker. The discovery workload is currently a
deterministic stub making **no** model calls; the inference path is added but exercised in tests
only via the Elixir broker with a mock provider.
**Primary Dependencies**: existing only. Broker HTTP listener uses Erlang/OTP stdlib (`:inets`
`httpd` or a minimal `:gen_tcp` line server over the mounted UDS) — **no new Elixir dependency**.
`CredentialProxy` (004), `SpendLedger` (005), `StateStore`, `DateTime`. Python side: the existing
HTTP client already vendored for the workload (or stdlib) pointed at the broker socket; mocked out
of all tests.
**Storage**: the existing persisted single-writer `spend_ledger` term-file
(`data/spend_ledger.term`, gitignored). **No new store, no schema change** — the entry already
carries `{spent, window_start}`; `spent` is now interpreted as integer micro-dollars. The per-model
price table and the `:model_key` credential live in `Application` env (config), like 004's
`:credentials`.
**Testing**: ExUnit, deterministic only. New `test/agent_os/inference_broker_test.exs` (price math,
cap pre-check + post-meter breach, fail-closed missing price, one-call overshoot, identity binding,
agent never sees price/cap/usage) with a mock `provider_fn` returning a canned usage payload. New
inference-only-breach + combined-budget cases in `test/agent_os/run_supervisor_test.exs`. Dollar
render cases in `test/agent_os/inventory_test.exs`. No Docker, no live LLM, no network in any test
(Constitution IV); a fixed price table, a small dollar cap, and an injected `:now` (005).
**Target Platform**: Linux/macOS host (unchanged).
**Project Type**: Single project — BEAM control plane + Python agent workload across the boundary.
This feature **deliberately** adds a boundary crossing (agent → broker for inference); it is the
point of the feature (spec SCOPE).
**Performance Goals**: N/A — per-call price math is O(1) integer arithmetic; the broker is off any
hot loop and gated by the (mocked-in-test, real-in-prod) provider latency.
**Constraints**: No change to 005's window/reset/kill/restart-exemption/visibility **model**
(FR-017). Dollars are exact integer micro-dollars, never float (FR-009). The agent never sees or
sets usage, price, or cap (FR-002, Principle X); the broker holds the key, the agent holds none
(FR-001, Principle XI). The broker refuses inference the instant `spent` reaches the cap (FR-014);
fail-closed on a missing model price (FR-015). Egress from the sandbox is substrate-controlled and
limited to the broker socket; the agent cannot widen it.
**Scale/Scope**: One new module (`AgentOS.InferenceBroker`) + one new pure price helper (or a
function on the broker), edits to `RunWorker` (inference-only pre-gate breach; dollar costs),
`Connector` (re-denominate `cost` to micro-dollars), config (price table + `:model_key` in prod),
the discovery manifest (cap in micro-dollars), and a thin Python inference-client shim. `Inventory`,
`SpendLedger`, `RunSupervisor`, `Gate` unchanged in logic (Inventory only changes unit formatting).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Simplicity First | PASS | One new module (broker) + a price helper; the metering reuses 005's `SpendLedger` and `spend_ledger` store and the existing `StateStore` single writer. Transport is a stdlib UDS line server, no web framework, no new dep. Provider call is a default-arg function, not a behaviour zoo. The hardened/production inference proxy is explicitly out of scope. |
| II. Explicit Scope Control | PASS | Exactly the spec: change the cost source (dollars) and inference's metering point (pre-action, at the broker). No new `on_breach` values, no rolling windows, no v3 generation, no broker hardening beyond a prototype pass-through. The boundary change is in-scope and called out by the spec. |
| III. Test-Driven Backend | PASS | Broker price math, cap pre/post checks, fail-closed, overshoot, identity binding, and the run-worker inference-only breach are backend logic — built test-first (red→green). The Python shim is integration/manual-walkthrough, not unit-tested (per III). |
| IV. No Live Dependencies in Tests | PASS | The provider call is an injected `provider_fn` returning a canned usage payload; a fixed price table; a small cap; injected `:now`. No live LLM, no network, no Docker. |
| V. Strong Typing, No Bare Maps | PASS | `InferenceBroker` carries `@type`/`@spec` for the request, the usage record, and the price entry (structs/typespecs, not bare maps). Micro-dollars are integers. Dialyzer clean. The ledger entry keeps its 005 shape, accessed through `SpendLedger`. |
| VI. Loud Failures | PASS | Fail-closed (missing price, over-cap) logs a distinct line; a spend breach logs `status=killed failure_cause=spend_breach` (005); the agent-facing response carries no internals. No silent meter-zero. |
| VII. Self-Documenting | PASS | Every new function gets `@doc`/`@moduledoc`; the price-math, the pre/post cap check, and the identity-binding blocks get intent comments. |
| VIII. Legibility | PASS | Strengthened: per-agent **dollar** spend is readable on the standing inventory from persisted state, without asking the agent (005 render reused). |
| IX. Substrate Owns State & Lifecycle | PASS | `StateStore` stays the single writer for `spend_ledger`; the broker mutates it only via a message, like `RunWorker`. The broker is invocation-adjacent (serves a running invocation), not a long-lived agent. No agent-specific vocabulary enters `lib/agent_os/`: model id, price, and cap come from config/manifest, not substrate identifiers. |
| X. No Ambient Authority | PASS | Cap, window, price, and usage are control-plane-owned and never seen or set by the agent; the per-run broker token binds identity server-side so the agent cannot self-confer a different cap or another agent's budget. The inference key is held by the broker via `CredentialProxy`, never the agent. |
| XI. Deterministic Gate Is the Only Firewall | PASS, strengthened | The broker is a deterministic substrate-side chokepoint that holds the inference credential; the LLM-running agent holds no key and cannot call the provider out-of-band. Metering and the cap decision are deterministic and substrate-side. |
| XII. Enforcement Precedes Generation | PASS | Pure enforcement (v2) work; no generation (v3) anything. |

**Result**: PASS. No violations; Complexity Tracking table omitted.

## Project Structure

### Documentation (this feature)

```text
specs/006-dollar-spend-metering/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output — routing, egress lock, price table, units, breach wiring
├── data-model.md        # Phase 1 output — entities & their micro-dollar shapes
├── quickstart.md        # Phase 1 output — exercising the broker, the runaway kill, the budget, the render
├── contracts/           # Phase 1 output
│   ├── inference-broker.md   # complete/2 contract: request, usage, price, cap pre/post, breach
│   ├── broker-boundary.md    # agent↔broker wire contract over the UDS + per-run token identity
│   └── run-worker-spend.md   # inference-only pre-gate breach + combined dollar budget
├── checklists/
│   └── requirements.md  # Spec quality checklist (from /speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/agent_os/
├── inference_broker.ex      # NEW — meter inference dollars, cap pre/post check, fail-closed price,
│                            #        call provider via CredentialProxy(:model_key), persist to ledger
├── inference_price.ex       # NEW (or a section of the broker) — pure micro-dollar price math +
│                            #        price-table lookup (fail-closed on missing model)
├── run_worker.ex            # EDIT — pre-gate inference-only breach (spent >= cap ⇒ kill, 0 actions);
│                            #        dollar costs flow through the existing post-gate increment
├── connector.ex             # EDIT — `cost` values re-denominated to integer micro-dollars
├── inventory.ex             # EDIT — format spent/cap as dollars (unit only; render logic reused)
├── spend_ledger.ex          # UNCHANGED — window/reset helper reused as-is
├── run_supervisor.ex        # UNCHANGED — {:killed, :spend_breach} restart-exemption reused
├── credential_proxy.ex      # UNCHANGED — :model_key resolved via with_credential
├── gate.ex                  # UNCHANGED — allow/deny/recipient/method logic untouched (FR-017)
└── application.ex           # EDIT — start the InferenceBroker (listener) in the supervision tree

config/config.exs            # EDIT — :inference_prices table; :model_key credential (prod from env)
manifests/discovery.md       # EDIT — spend.cap expressed in micro-dollars (data, not logic)

agents/discovery/
└── main.py                  # EDIT (thin) — route model calls through the broker UDS using the
                             #        substrate-injected per-run token; no provider key on the agent

test/agent_os/
├── inference_broker_test.exs   # NEW — price math, cap pre-check + post-meter breach, fail-closed
│                               #        missing price, one-call overshoot, identity binding,
│                               #        agent never sees price/cap/usage; mock provider_fn
├── run_supervisor_test.exs     # EDIT — inference-only breach with zero actions ⇒ killed + no restart;
│                               #        combined inference+action dollars vs one cap
└── inventory_test.exs          # EDIT — spent/cap rendered in dollars; zero after window reset
```

**Structure Decision**: Single project, control-plane-centric with one deliberate boundary
crossing. The genuinely new logic — meter a provider call into dollars and enforce the cap per call
— lives in `AgentOS.InferenceBroker` plus a small pure price helper. Everything else is surgical:
`RunWorker` gains one pre-gate inference-only breach branch; `Connector` costs are re-denominated;
`Inventory` changes a unit. The broker writes into the existing `spend_ledger` via the existing
`StateStore` single writer (no second writer, Principle IX) and uses the existing `SpendLedger`
window helper (no duplicated window logic). The broker listener is the only new supervision-tree
entry.

## Phase 0: Research

See [research.md](./research.md). The three spec clarifications (per-call cap granularity,
fail-closed missing price, single dollar budget) and the two `/speckit-clarify` decisions (one-call
overshoot, integer micro-dollars) are settled in the spec. Research resolves the design decisions
this plan introduces: (1) the routing transport (local HTTP over a substrate-mounted UDS) and the
sandbox egress lock; (2) per-run identity binding so the untrusted agent cannot spoof cap/budget;
(3) the price-table location and shape; (4) how a mid-run inference breach is translated into 005's
run kill + batch drop; (5) re-denominating connector `cost` to micro-dollars. No NEEDS CLARIFICATION
remains.

## Phase 1: Design & Contracts

- **Data model**: [data-model.md](./data-model.md) — the Inference Request (agent→broker), the
  provider Usage Record, the Per-Model Price entry (micro-dollars), the reused Spend Ledger Entry
  (now micro-dollars), and the Per-Run Broker Token.
- **Contracts**: [contracts/](./contracts/) — `InferenceBroker.complete/2`; the agent↔broker wire
  contract + token identity; and the `RunWorker` inference-only breach + combined-budget contract.
- **Quickstart**: [quickstart.md](./quickstart.md) — exercise the metered call, the runaway
  zero-action kill, the combined budget, the window reset, and the dollar render deterministically.
- **Agent context**: the `<!-- SPECKIT -->` block in `CLAUDE.md` is updated to point at this plan.

**Post-Design Constitution Re-Check**: PASS — the design adds one chokepoint module + a pure price
helper and surgical edits; no new dependency, no new store, one new supervision entry (the broker
listener); legibility strengthened; the gate and 005's enforcement model untouched; the agent gains
no credential and no visibility into price/cap/usage.

## Complexity Tracking

No constitution violations — table omitted.
