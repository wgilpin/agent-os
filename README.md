# Agent OS

A deterministic BEAM/OTP control plane — a *kernel* — that declares, enforces,
observes, and supervises invocation-scoped agent processes.

This is a **prototype** built to learn whether the architecture feels right. It is
not a production system.

## The thesis

An autonomous agent (here, a discovery agent running unattended against the live web)
should be safe to leave running even if it misbehaves or is compromised. The way to get
there is not to trust the agent, but to put a **substrate** around it that owns
everything the agent is not allowed to own: its state, its lifecycle, its credentials,
its budget, and its permission to act.

The substrate is deterministic and sits between the agent and the outside world. The
agent proposes; the substrate decides. Every decision is made from declared policy and
persisted state — never by asking the agent.

## Goals

- **Isolation** — the agent runs inside a sandbox, separate from the host process,
  filesystem, environment, and substrate state. It can only touch its explicitly
  granted inputs and outputs.
- **Enforcement by manifest** — what an agent may do is declared up front in a manifest
  and enforced by a deterministic gate. The agent cannot widen its own permissions.
- **Invisibility** — the agent never sees its own manifest, caps, prices, or usage.
  Policy is control-plane-owned, not negotiable from inside.
- **No ambient authority** — credentials are held by the substrate and brokered to the
  agent on a per-use basis. The agent holds no keys and cannot self-confer capabilities.
- **Spend metering with real kill-on-breach** — every agent runs against a per-agent
  dollar budget. Inference is metered at a substrate-side chokepoint (the inference
  broker) that holds the model key, reads provider-reported usage, converts to integer
  micro-dollars, and kills a run the instant it crosses its cap — including a zero-action
  runaway bill.
- **Legibility** — the substrate always presents a standing inventory of what exists and
  a legible trace of what happened, readable without asking the agent.

## Architectural invariants

These are locked and not re-litigated per feature:

- **VIII. Legibility is non-negotiable** — the one principle that survives if only one does.
- **IX. The substrate owns state & lifecycle** — single writer per mutable state; the
  substrate schedules, the agent does not.
- **X. No ambient authority** — capabilities are declared, never self-conferred.
- **XI. The deterministic gate is the only firewall** — a substrate-side, deterministic
  chokepoint is the sole thing standing between a proposed action and the world.
- **XII. Enforcement precedes generation** — get enforcement right before adding any
  generative capability.

## Stack

- **Control plane:** Elixir ~> 1.20 on BEAM/OTP (`lib/agent_os/`).
- **Agent workload:** a sandboxed Python discovery agent (`agents/discovery/`), shipped
  as a deterministic stub for tests.
- **Tests:** ExUnit, deterministic only — no live LLM, no network, no Docker in any test.

## Roadmap so far

Built incrementally as numbered specs under `specs/`:

1. **001 — Isolate the discovery agent**: run it contained, separate from the host.
2. **002 — Manifest enforcement**: declared permissions, enforced by the gate.
3. **003 — Manifest invisibility**: the agent cannot see its own policy.
4. **004 — Credential proxy**: the substrate holds keys and brokers them per-use.
5. **005 — Spend metering & real kill-on-breach**: per-agent budgets with a hard kill.
6. **006 — Dollar spend metering**: real dollars, metered at the inference chokepoint.

Planning artifacts (spec, plan, tasks, contracts) for each live in
`specs/<NNN>-<name>/`. The binding principles live in
`.specify/memory/constitution.md`.
