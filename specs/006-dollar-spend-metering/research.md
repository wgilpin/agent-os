# Phase 0 Research: Dollar Spend Metering via an Inference Chokepoint

All spec-level open questions were resolved before this plan: per-call cap granularity, fail-closed
on a missing price, single dollar budget (spec `## Clarifications`), plus one-call overshoot and
integer micro-dollars (`/speckit-clarify`). This document resolves the **design** decisions the plan
introduces. No `NEEDS CLARIFICATION` remains.

---

## R1 — Inference routing transport (how the agent reaches the broker)

**Decision**: A substrate-side **inference broker** exposed to the sandboxed Python workload over a
**unix-domain socket (UDS) mounted into the container**, speaking a minimal local HTTP request
(`POST /v1/inference`). The container keeps `network: "none"`; the only channel out is the single
mounted socket. The agent's model client is pointed at the broker (base address = the socket).

**Rationale**:
- Honours the spec's stated point — a *real* boundary change: the agent routes model calls out
  through the substrate instead of calling the provider directly (FR-001).
- Strongest isolation with the least machinery (Principle I): with `network: none` the container has
  no network stack at all; the only reachable endpoint is the broker socket the substrate chose to
  mount. There is nothing else to firewall and no internet route to leak to.
- No new Elixir dependency — an OTP stdlib listener (`:inets`/`:gen_tcp`) over the UDS is enough for
  a prototype pass-through. A production-grade proxy is explicitly out of scope.

**Alternatives considered**:
- *Local TCP on an `internal: true` docker network* (broker as the sole reachable host): also blocks
  internet egress, but adds a custom network and an IP/port the agent could probe. UDS is simpler and
  has a smaller surface. Kept as a fallback if a model client cannot speak HTTP-over-UDS.
- *Port back-channel over the existing stdio* (multiplex inference req/resp on the PortRunner pipe):
  reuses the transport and keeps `network: none`, but rewrites the one-shot port into an interactive
  protocol — more boundary complexity than a single socket for no isolation gain.
- *Broker module, transport deferred* (drive the broker directly in tests, stub the Python wiring):
  simplest, but does not change the running boundary — under-delivers the spec's explicit point.

**Egress is substrate-controlled (Principle X)**: the container's mount and `--network` come from
`Sandbox.build_argv`, never from the agent. The agent cannot widen its own egress; it can reach the
broker socket and nothing else.

---

## R2 — Per-run identity binding (the untrusted agent must not spoof cap/budget)

**Decision**: The substrate injects a **per-run opaque broker token** into the container (env var)
and holds a server-side map `token → {agent_name, manifest}`. The agent includes the token on each
inference request; the broker resolves the agent **server-side** from the token. The agent never
sends — and the broker never trusts — an agent-supplied identity, cap, model price, or spend figure.

**Rationale**:
- Without this, an untrusted agent could claim another agent's identity (draining its budget) or a
  larger cap. Binding identity to a substrate-issued token closes that (Principle X: a holder cannot
  self-confer authority; the thing granted never classifies its own danger).
- Keeps the wire contract minimal (FR-012, spec 003 invisibility): request carries only
  `{model, messages}` + token; response carries only the completion. No cap, price, usage, or spend
  ever crosses back to the agent (FR-002).

**Alternatives considered**:
- *Trust an `agent_name` field in the request*: rejected — agent is untrusted, this is spoofable.
- *Per-agent UDS path as the identity*: viable (the socket the agent can see encodes who it is), and
  is the natural fallback if env-var token injection is awkward; the token is chosen as primary
  because it survives socket-sharing and is explicit.

---

## R3 — Price table: location, shape, and staleness

**Decision**: A per-model price table in `Application` env (`:agent_os, :inference_prices`),
mirroring how 004 stores `:credentials`. Shape: `model_id => %{input: micro_usd_per_token, output:
micro_usd_per_token}` as **integers** (micro-dollars). On a model with **no entry**, the broker
**fails closed**: it does not call the provider and returns a spend-breach/blocked result (FR-015).

**Rationale**:
- Config-as-source matches the existing hard-wired v0 provisioning surface (`config/config.exs`) and
  keeps the price out of the agent's reach (Principle X).
- Integers in micro-dollars avoid float drift (FR-009); per-token prices are deep sub-cent, so cents
  would round to zero.
- Fail-closed prevents the agent from evading metering by selecting an unpriced model (an
  untracked-spend hole). Loud log on the closed path (Principle VI).

**Alternatives considered**:
- *Separate config file / JSON*: unnecessary for a handful of models; `Application` env is simplest.
- *Fail-open (meter zero + warn)*: rejected at spec clarification — creates an exploitable hole.

**Models**: real prices are for Gemini **3-series** only (Constitution tech stack); tests use a
fixed fictitious table so values are deterministic and obvious.

---

## R4 — Dollar representation

**Decision**: **Integer micro-dollars** (1 unit = 1e-6 USD) everywhere: ledger `spent`, manifest
`cap`, price-table entries, and the metered amount. Compared as integers. (Spec FR-009 / clarify.)

**Rationale**: exact, no float drift, holds sub-cent per-token prices precisely with ample headroom.
The connector registry `cost` values are re-denominated to micro-dollars (R6).

**Alternatives considered**: cents (rounds per-call cost to zero); `Decimal` (heavier, unnecessary
once an exact integer unit removes drift).

---

## R5 — Metering point and how a mid-run inference breach kills the run

**Decision**: Inference is metered **pre-action**, per call, at the broker, into the **same**
`spend_ledger` entry 005 uses. The broker enforces the cap **per call** (FR-014):

1. Apply `SpendLedger.current_entry/3` (005) to the agent's entry with the injected `:now` (window
   reset if rolled over).
2. **Pre-check**: if `spent >= cap`, do **not** call the provider — return a spend-breach result and
   flag the run's breach. (Handles "already over from earlier in the window/run".)
3. Else call the provider via `CredentialProxy.with_credential(:model_key, …)`, read usage, compute
   `dollars = in_tokens·in_price + out_tokens·out_price`, persist `spent + dollars` via `StateStore`.
4. **Post-meter check**: if the new `spent >= cap`, flag the run's breach (the crossing call was
   metered and counted — one-call overshoot; no pre-estimation). Otherwise return the completion.

A flagged breach becomes 005's kill via **two reinforcing mechanisms**, no new kill model needed
(FR-017):
- The broker **refuses all further inference** for that run (every subsequent call hits the
  pre-check and returns breach) — so a runaway loop stops burning dollars *the moment it crosses*,
  even if the untrusted agent ignores the response.
- `RunWorker` gains a **pre-gate inference-only breach** check: after computing the windowed entry,
  if `spent >= cap` the run is killed and the whole batch is dropped — **even with zero proposed
  actions** (US2) — reusing the existing `dispatch_on_breach(:kill, …)` path that returns
  `{:killed, :spend_breach}` and the `RunSupervisor` restart-exemption.

**Rationale**: Reuses every piece of 005 (the store, the window helper, the kill signal, the
restart-exemption, the run-log line). The only genuinely new control-flow is the broker's per-call
check and `RunWorker`'s zero-action breach branch. Forcibly SIGKILLing the Python mid-run is *not*
required for the prototype — refusing further inference caps the bill, and dropping the batch at run
end makes the kill a real stop of the run's effects (broker hardening is out of scope).

**Alternatives considered**:
- *Pre-estimate cost and block before calling* (prevent any overshoot): rejected at clarify — needs
  an `max_tokens`-based estimate the agent could influence; one-call overshoot with ground-truth
  usage is simpler and honest.
- *Meter on the effector (like a credential)*: rejected — inference cost is incurred pre-action, so
  effector-time metering reproduces exactly the blind spot this feature exists to close.

---

## R6 — Combined budget and re-denominating connector cost

**Decision**: **One** `spend_ledger` entry, **one** cap. Inference dollars (broker, pre-action) and
per-action dollars (`RunWorker`'s existing post-gate `total_approved_cost` increment) both add to
`spent`. The `Connector` registry `cost` values are re-denominated from arbitrary units to integer
**micro-dollars**: free connectors → `0`; a connector with a real downstream dollar cost → that
cost. The manifest `spend.cap` and `config` cap are likewise expressed in micro-dollars (data
change, not logic).

**Rationale**: Matches the clarified "single dollar budget, two real contributors" and reuses
005's post-gate increment mechanism unchanged. General-purpose agents incur non-LLM dollar costs
(e.g. a paid API connector), so per-action dollars are a real contributor, not just latent.

**Alternatives considered**: separate inference/action sub-budgets (rejected at clarify — diverges
from 005's single ledger, adds a second cap axis).

---

## R7 — Provider call injection for deterministic tests

**Decision**: The broker's provider call is an **injectable function** (`:provider_fn` opt /
`Application` env, default the real Gemini 3-series client). Tests pass a mock returning a canned
`%{input_tokens, output_tokens, completion}` payload, so the metered dollars are computed
deterministically with **no live LLM** (Constitution IV, FR-006, SC-001/SC-007).

**Rationale**: A default-arg function is the simplest seam (Principle I) — no behaviour module
ceremony. Keeps every test offline and deterministic; the real client is never exercised in tests.

**Alternatives considered**: a `@behaviour` + Mox (heavier than needed for one function); a compile
-time stub (less flexible than a per-call injected fn).

---

## Summary of decisions

| # | Decision | Source |
|---|----------|--------|
| R1 | Broker over a mounted UDS; container stays `network: none` | plan, Principle I/X |
| R2 | Per-run substrate-issued token binds agent identity server-side | Principle X |
| R3 | Price table in `Application` env, integer micro-dollars, fail-closed on miss | FR-002/003/015 |
| R4 | Integer micro-dollars everywhere | FR-009 / clarify |
| R5 | Per-call meter + cap (pre-check + post-meter), breach ⇒ broker refuses + RunWorker zero-action kill | FR-006/014, US2 |
| R6 | One ledger / one cap; registry `cost` re-denominated to micro-dollars | FR-008/016 |
| R7 | Injectable `provider_fn`; mock in tests, no live LLM | Constitution IV, FR-006 |
