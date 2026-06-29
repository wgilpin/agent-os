# Feature Specification: Dollar Spend Metering via an Inference Chokepoint

**Feature Branch**: `006-dollar-spend-metering`
**Created**: 2026-06-29
**Status**: Draft
**Input**: User description: "Dollar spend metering via an inference chokepoint: 'spend' becomes real money, dominated by LLM inference cost (tokens × price), metered trustlessly in the control plane and enforced through the windowed ledger and kill that already exist. Follow-on to spec 005-spend-metering; becomes spec 006-dollar-spend-metering."

## Context

This feature is the follow-on to `005-spend-metering` (roadmap plan 03-04, now merged). 005
built the spend **enforcement mechanism** — a fixed resetting per-agent window, a
breach-triggered `on_breach` kill that is restart-exempt, and per-agent spend visibility — but
sourced the metered quantity from an **arbitrary per-action weight** in the connector registry
(`kv_append=1`, `external_send=2`). Those units are not useful: a "cap of 5/day" maps to nothing
an operator can reason about, and — more importantly — the meter ignores the dominant, volatile,
runaway-prone cost entirely: LLM inference. The action-cost meter records **zero** for exactly
the failure mode operators most fear (an agent that loops and burns inference dollars overnight),
because that cost is incurred on the untrusted side **before any action is proposed**.

This feature replaces the **source** of the metered number with **real dollars** while reusing
005's enforcement model unchanged. The dominant term is inference cost: the agent's LLM calls are
routed through a substrate-side **inference broker** (the same chokepoint pattern as the 004
credential proxy), so the control plane — not the untrusted agent — reads the provider's returned
token usage, multiplies by a per-model price, and meters the resulting dollars against the cap.
In v2 **inference is the only priced source** — only LLM calls have a real, provider-reported
dollar cost; no connector declares a real per-action dollar cost today. The spend ledger is
therefore a single dollar budget against one cap, fed by inference dollars, and is unit-agnostic
enough that a per-action dollar cost would sum into it should a connector ever declare one (a
latent capability, not exercised in v2). Because the broker holds the inference key (via the
credential proxy) and the agent never does, this also tightens Principles X/XI: the agent can no
longer call the model out-of-band.

The following already exist and MUST NOT be re-specified here — this feature builds on them:

- 005's fixed-resetting per-agent `spend_ledger` and the `SpendLedger` window/reset helper.
- 005's `on_breach` kill dispatch and its restart-exemption (intentional-stop signalling).
- 005's per-agent spend **visibility render** (standing inventory: spent / cap / window).
- 004's **credential proxy**, which already holds an inference-only key separately, and its
  `with_credential` closure pattern.
- The injectable clock (`:now`) used by 005 for deterministic window-boundary tests.

What this feature **changes** is the **cost source** and its **metering point**: the metered
quantity becomes dollars (inference tokens × per-model price, plus per-action dollar cost), and
inference is metered **pre-action**, at the broker, in the control plane. This **deliberately
breaks** 005's "control-plane only, no boundary change" constraint — the agent must now route LLM
calls through the substrate broker instead of calling the provider directly. That boundary change
is the point of the feature, not an accident.

## Clarifications

### Session 2026-06-29

- Q: Is the inference cap checked per model call (so a runaway loop is stopped the moment it
  crosses, mid-run) or once per run at the gate as 005 does for actions? → A: **Per model call
  (mid-run)**. The cap is evaluated after each inference call; the moment cumulative dollars cross
  the cap, `on_breach` fires and no further inference proceeds. 005's per-run check is too coarse —
  a single run's loop could overshoot the cap before the check fires, which is exactly the
  runaway-bill case this feature exists to stop.
- Q: When the running model has no entry in the per-model price table, does the broker fail closed
  (block the inference call) or fail open (meter zero and warn)? → A: **Fail closed (block)**. An
  unpriced model cannot be metered, so allowing the call would create an untracked-spend hole the
  agent could exploit by selecting an unpriced model. The broker blocks the call.
- Q: Do inference dollars and per-action dollars share one ledger entry and one cap, or separate
  sub-budgets? → A: **Single dollar budget** with **two real contributors**. Inference dollars
  (provider-reported tokens × price) are the dominant, volatile term, but because these are
  general-purpose agents they can also incur non-LLM dollar costs — e.g. a connector that makes a
  paid API call downstream. Both inference dollars and per-action dollars are denominated in
  dollars and summed into the same per-agent ledger, checked against one cap — one dollar meter,
  not two.
- Q: The broker only learns a call's dollar cost from the provider's response (usage comes back
  after the call completes). On the call that crosses the cap, can spend overshoot, or must the
  broker pre-estimate to prevent it? → A: **Allow one-call overshoot.** Before each call the broker
  checks cumulative-so-far: if already at/over the cap it blocks (does not call); otherwise it
  calls, meters the actual provider-reported usage, then checks. The crossing call is metered and
  counted, so cumulative spend may exceed the cap by at most that one call's cost. No pre-estimation
  (which the agent could influence via `max_tokens`) is used — only ground-truth usage.
- Q: What exact integer unit represents dollars in the ledger, cap, and price table? → A: **Integer
  micro-dollars** (1 unit = 1e-6 USD). Per-token prices are deep sub-cent, so cents would round to
  zero per call; micro-dollars hold realistic per-token prices exactly as integers with ample
  headroom and no float drift. `cap`, `spent`, and price-table entries are all integer micro-dollars.

## User Scenarios & Testing *(mandatory)*

The "user" of this feature is the human operator who declares and runs the (still hand-written)
agent, plus the substrate itself which must enforce that declaration. The agent is the untrusted
party and is never a beneficiary of trust. The operator declares `spend: {cap, window, on_breach}`
in the manifest — where `cap` is now a **dollar amount** — and expects the substrate to meter the
agent's real dollar spend (dominated by inference), enforce the per-window cap as the agent
*thinks* (not just after it proposes actions), kill the run on breach as declared, and let the
operator see dollars spent per agent — all without trusting, querying, or letting the agent
self-report usage, price, or cap.

### User Story 1 - Inference dollars are metered trustlessly at the broker and counted against the cap (Priority: P1)

The agent's LLM calls are routed through a substrate-side inference broker. For each call, the
broker (holding the inference key via the 004 credential proxy) calls the provider, reads the
provider's returned token usage (input/output tokens) as ground truth, multiplies by the per-model
price from the substrate's price table, and meters the resulting dollar amount into the agent's
spend ledger. The agent never sees or sets the usage, the price, or the cap.

**Why this priority**: This is the core of the feature — moving the metered quantity to real
inference dollars, computed trustlessly in the control plane. Everything else (per-action dollars,
visibility, the runaway-kill) depends on inference being metered correctly and untrustedly first.

**Independent Test**: With a mock inference provider returning a canned usage payload and a fixed
price table, route an inference call through the broker and assert the dollar figure metered into
the ledger equals `input_tokens × input_price + output_tokens × output_price` computed
deterministically — with no live LLM call. Assert the agent-side request carries no price/cap/usage
and the agent receives only the completion.

**Acceptance Scenarios**:

1. **Given** a mock provider returning a fixed usage payload and a fixed per-model price table,
   **When** the broker meters a call, **Then** the dollar figure is computed deterministically from
   provider-reported tokens × price, summed into the agent's spend ledger, with no live LLM call.
2. **Given** an inference call, **When** the broker handles it, **Then** the provider token usage —
   not any agent-supplied number — is the metered quantity (ground truth from the API response).
3. **Given** the broker holds the inference key via the credential proxy, **When** the agent
   attempts inference, **Then** it must route through the broker (it has no key to call the
   provider out-of-band), tightening Principles X/XI.

---

### User Story 2 - A runaway inference loop is killed even with zero proposed actions (Priority: P1)

An agent that loops, burning inference dollars with no gate-passing actions, accumulates dollar
spend in its ledger from the broker's metering alone. When cumulative inference dollars would push
spend over the dollar cap, the declared `on_breach` (kill) fires — stopping the run — even though
the agent has proposed zero actions. This is the runaway-bill case the 005 action meter missed.

**Why this priority**: This is the operator's real need — protection from a runaway bill. It is the
explicit failure mode 005 could not catch because action cost is metered post-gate. It is
co-critical with US1: metering inference (US1) is only valuable if breaching it stops the run (US2).

**Independent Test**: With a small dollar cap and a mock provider, drive repeated inference calls
(simulating a loop) with zero actions proposed; assert that when cumulative inference dollars cross
the cap the run is killed via the declared `on_breach`, and that the supervisor treats it as an
intentional stop (no restart) — reusing 005's restart-exemption. Deterministic, no live model.

**Acceptance Scenarios**:

1. **Given** a dollar cap and an agent making inference calls but proposing no actions, **When**
   cumulative inference dollars would exceed the cap, **Then** the declared `on_breach` (kill)
   fires and the run is stopped.
2. **Given** a breach triggered by inference spend, **When** the supervisor observes the stop,
   **Then** it is treated as an intentional stop and restart-once-and-alert is NOT invoked (reusing
   005's restart-exemption unchanged).
3. **Given** a breach triggered by inference spend mid-run, **When** the kill fires, **Then** the
   run's proposed actions (if any) are also dropped — consistent with 005's drop-the-whole-batch
   decision.

---

### User Story 3 - Real per-action dollar costs are summed into the same dollar ledger (Priority: P2)

These are general-purpose agents, so spend is not only inference. A connector whose downstream
call costs money (e.g. a paid third-party API) declares that cost in dollars. When such an action
executes, its dollar cost is summed into the **same** per-agent spend ledger as inference dollars —
one dollar meter, metered against one dollar cap — so the operator's budget reflects total real
spend, not two disjoint numbers.

**Why this priority**: It completes the "spend = real dollars" picture so action cost and inference
cost are one comparable budget against one cap. It depends on US1's dollar ledger existing, and is
less urgent than the runaway-kill (US2), so P2.

**Independent Test**: With a connector carrying a real dollar per-action cost and a mock inference
provider, accumulate both inference dollars and an executed action's dollar cost; assert both land
in the same per-agent ledger and are checked against the same cap. Deterministic.

**Acceptance Scenarios**:

1. **Given** a connector with a real per-action dollar cost, **When** such an action executes,
   **Then** its dollar cost is summed into the same per-agent ledger as inference dollars.
2. **Given** both inference dollars and per-action dollars accrued in a window, **When** the cap is
   evaluated, **Then** it is evaluated against their combined dollar total (one budget, one cap).

---

### User Story 4 - Dollar spend resets at the window boundary and is visible per agent in dollars (Priority: P2)

When the fixed window boundary passes, dollar spend resets to zero and the agent may spend again —
reusing 005's window/reset semantics unchanged, now denominated in dollars. The operator inspects
the standing inventory and sees, per agent, current spend in dollars for the current window (spent
/ cap / window) — reusing 005's visibility render, now showing dollars.

**Why this priority**: Window/reset and visibility are reused wholesale from 005; the only change is
the unit (dollars). It is operator-facing completion rather than core enforcement, so P2.

**Independent Test**: After accruing dollar spend within a window, advance the injected clock past
the boundary and assert spend resets to zero (005's reset semantics). Render the standing inventory
and assert per-agent spent / cap / window is reported in dollars, sourced from the ledger, without
querying the agent. Deterministic.

**Acceptance Scenarios**:

1. **Given** dollar spend accrued within a window, **When** the window boundary passes (clock
   advanced in test), **Then** dollar spend resets to zero and the agent may spend again — reusing
   005's window/reset semantics unchanged.
2. **Given** any run, **When** the operator inspects the standing inventory, **Then** current spend
   is shown per agent in dollars for the current window (spent / cap / window), read from the ledger
   without communicating with the agent.

---

### Edge Cases

- **Mid-run crossing**: an inference call whose metered dollars push cumulative spend to or over the
  cap triggers `on_breach` immediately (the cap is checked per call, FR-014); the run is stopped and
  its proposed actions dropped (consistent with 005). Cumulative spend may exceed the cap by at most
  that one crossing call's cost, since cost is known only from the provider response.
- **Already over cap at call time**: if cumulative spend is already at or over the cap when the next
  inference call is requested, the broker blocks it before calling (no further provider call) and
  fires `on_breach`.
- **Zero proposed actions**: a run that breaches purely on inference spend is killed even though no
  action was ever proposed (the runaway-bill case).
- **Model with no price entry**: the broker fails closed and blocks the call (FR-015); the agent
  cannot dodge metering by selecting an unpriced model.
- **Window rollover with dollar spend**: dollar spend in window W resets to zero at W's boundary,
  reusing 005's reset; a run straddling the boundary uses the reset value (no compounding).
- **Float drift**: dollar amounts MUST be represented without floating-point drift (see Assumptions);
  metered amounts and the cap are compared in the same exact integer unit.
- **Provider returns no/partial usage**: if the provider response lacks token usage, the broker must
  not silently meter zero in a way the agent could exploit — usage must be present to compute cost
  (treated like the missing-price case unless the provider guarantees usage).
- **Cap boundary inclusivity**: reuse 005's inclusive-cap semantics — spend landing exactly at the
  cap is allowed; only strictly-over is a breach.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The agent's LLM calls MUST be routed through a substrate-side inference broker; the
  agent MUST NOT call the inference provider directly. The broker holds the inference key via the
  004 credential proxy (`with_credential`), so the agent has no key to call the model out-of-band.
- **FR-002**: The broker MUST read token usage (input/output tokens) from the **provider's API
  response** as ground truth and compute the dollar cost as tokens × per-model price. The agent MUST
  NOT see, set, or self-report the usage, the price, or the cap (Principle X).
- **FR-003**: The per-model price table MUST live in substrate config, owned by the control plane;
  the agent has no access to it.
- **FR-004**: The dollar cost computed by the broker MUST be metered into the agent's spend ledger
  (reusing 005's per-agent `spend_ledger`), and counted against the dollar `cap`.
- **FR-005**: A breach of the dollar cap MUST fire the declared `on_breach` (kill) — reusing 005's
  dispatch and restart-exemption unchanged — even when the agent has proposed **zero actions** (the
  runaway-inference case).
- **FR-006**: Inference spend MUST be metered **pre-action** (as the agent thinks), not post-gate;
  this is the deliberate metering-point change from 005, which meters action cost post-gate.
- **FR-007**: When a breach is triggered by inference spend mid-run, the run's proposed actions (if
  any) MUST also be dropped — consistent with 005's drop-the-whole-batch decision; a kill is a real
  stop of the run, not a logged warning.
- **FR-008**: A connector with a real per-action dollar cost MUST have that cost denominated in
  dollars and summed into the same per-agent ledger as inference dollars.
- **FR-009**: Dollar amounts MUST be represented as **integer micro-dollars** (1 unit = 1e-6 USD) —
  an exact integer unit with no floating-point drift. The ledger `spent`, the manifest `cap`, and
  every per-model price-table entry MUST use this same unit, and the metered amount and the cap MUST
  be compared as integers in that unit.
- **FR-010**: Dollar spend MUST reset at the fixed window boundary, reusing 005's `SpendLedger`
  window/reset helper and `window_start` semantics unchanged (only the unit changes to dollars).
- **FR-011**: Current spend MUST be visible per agent for the current window on the legible surface
  (standing inventory) as spent / cap / window denominated in dollars, read from the persisted
  ledger WITHOUT communicating with the agent — reusing 005's render, now in dollars.
- **FR-012**: The cross-boundary inference request/response contract MUST be minimal — carrying only
  what the broker needs to make the call and return the completion — with no manifest/envelope
  leakage to the agent (spec 003 invisibility preserved).
- **FR-013**: The current time used for window-boundary evaluation MUST remain injectable
  (005's `:now`) so window rollover and accumulation are testable deterministically.
- **FR-014**: The inference cap MUST be checked **per model call**. Before each call the broker MUST
  check cumulative spend-so-far: if it is already at or over the cap, the broker MUST NOT make the
  call and MUST fire `on_breach` (kill). Otherwise it makes the call, meters the actual
  provider-reported usage, and re-checks. The moment cumulative dollars reach or cross the cap,
  `on_breach` (kill) MUST fire and no further inference MUST proceed — stopping a runaway loop the
  instant it crosses, rather than waiting for a per-run check that a single run's loop could
  overshoot. Because cost is known only from the response, cumulative spend MAY exceed the cap by at
  most the cost of the single call that crosses it (the crossing call is metered and counted); the
  broker MUST NOT pre-estimate cost to prevent this (no agent-influenceable estimate is used).
- **FR-015**: When the running model has no entry in the price table, the broker MUST **fail closed
  (block the inference call)** — an unpriced model cannot be metered, so the agent MUST NOT be able
  to evade metering or incur untracked spend by selecting an unpriced model.
- **FR-016**: Inference dollars and per-action dollars MUST be accounted as a **single dollar
  budget** — one per-agent ledger entry, one cap — into which both are summed (not separate
  sub-budgets). Inference dollars are the dominant contributor; per-action dollar costs sum in
  alongside them.
- **FR-017**: This feature MUST NOT change 005's window/reset/kill/restart-exemption/visibility
  **model**; only the cost source (dollars) and inference's metering point (pre-action, at the
  broker) change.

### Key Entities *(include if feature involves data)*

- **Inference Broker**: the substrate-side chokepoint through which all agent LLM calls pass. Holds
  the inference key via the 004 credential proxy, calls the provider, reads provider-reported token
  usage, converts to dollars via the price table, meters dollars into the ledger, and returns only
  the completion to the agent. The agent's sole path to inference.
- **Per-Model Price Table**: control-plane config mapping a model identifier to its input/output
  per-token price. Read only by the substrate; never exposed to or set by the agent.
- **Spend Ledger Entry (per agent)**: 005's persisted, single-writer per-agent record of spend in
  the current window — now holding **dollars** (exact integer unit) rather than arbitrary units.
  Source of both enforcement and the operator render. Reused unchanged in structure.
- **Spend Constraint (manifest)**: 005's `{cap, window, on_breach}` per agent — `cap` is now a
  **dollar amount**, `window` and `on_breach` reused unchanged (`daily` / `kill` in v2).
- **Inference Usage Record**: the provider-reported input/output token counts for a single call —
  the ground-truth quantity the broker meters. Reported by the provider, never by the agent.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With a mock inference provider returning a canned usage payload and a fixed price
  table, the broker meters a dollar figure equal to tokens × price computed deterministically, with
  no live LLM call — verified in the deterministic suite.
- **SC-002**: An agent that loops burning inference with zero proposed actions is killed once
  cumulative inference dollars exceed the cap — the runaway-bill case the 005 action meter missed —
  and the supervisor does not restart it.
- **SC-003**: A connector with a real per-action dollar cost has that cost summed into the same
  per-agent ledger as inference dollars, checked against the same dollar cap.
- **SC-004**: After the window boundary passes (clock advanced in test), per-agent dollar spend
  resets to zero and the agent may spend again — reusing 005's window/reset semantics.
- **SC-005**: The operator can read per-agent spent / cap / window in **dollars** for the current
  window from the standing inventory without any communication with the agent process.
- **SC-006**: The agent cannot call the inference provider out-of-band (it holds no key) and cannot
  influence the metered dollar figure (usage and price are control-plane-sourced) — Principles X/XI.
- **SC-007**: The entire feature's behaviour is verified by deterministic tests only — no live LLM,
  no external service, no Docker — driven by a mock provider, a fixed price table, a small dollar
  cap, and an injected clock.

## Assumptions

- **Dollar representation**: dollars are represented as **integer micro-dollars** (1 unit = 1e-6
  USD) — chosen because per-token prices are deep sub-cent and cents would round to zero per call;
  micro-dollars hold them exactly as integers with no float drift (FR-009).
- **Inference routing mechanism**: the presumed default is that the substrate broker makes the
  provider call on the agent's behalf and returns the completion (mirroring 004's `with_credential`
  closure), rather than handing the agent a key or a token. The exact transport (local HTTP endpoint
  the Python workload calls vs. port message) and the minimal request/response contract (FR-012) are
  to be settled in the plan; this is HOW, not WHAT.
- **Pre-action vs post-action ordering**: inference is metered pre-action (at the broker, as the
  agent thinks); 005's action cost remains post-gate. A kill triggered by inference spend drops the
  run's actions too (FR-007), consistent with 005's batch-drop decision.
- **Window and on_breach**: `daily` and `kill` remain the only supported values in v2, reused from
  005 unchanged; only the unit of `cap`/`spent` changes to dollars.
- **Mock provider**: tests use a mock inference provider returning a canned usage payload; no live
  LLM, external service, or Docker is involved (Constitution IV).
- **Credential proxy reuse**: the 004 credential proxy already holds an inference-only key
  separately; the broker uses that existing mechanism rather than introducing new key handling.

## Out of Scope

- Any change to 005's window/reset/kill/restart-exemption/visibility **model** (only the cost source
  and inference's metering point change).
- New `on_breach` values beyond `kill`; rolling (non-fixed/sliding) windows.
- Multi-provider price reconciliation beyond a simple per-model price table.
- Caching or optimising inference.
- Any agent-generation (v3) work.
- Hardening the broker beyond a prototype pass-through (a production-grade inference proxy is later
  work).

## Dependencies

- 005's fixed-resetting `spend_ledger`, `SpendLedger` window/reset helper, `on_breach` kill dispatch
  + restart-exemption, and per-agent visibility render (spec 005) — landed.
- 004's credential proxy and its `with_credential` closure, holding an inference-only key separately
  (spec 004) — landed.
- The injectable clock (`:now`) for deterministic window/accumulation tests (spec 005) — landed.
- The deterministic gate and run-worker boundary (spec 002 / 005) — landed.
