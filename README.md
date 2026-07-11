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

**The language boundary is the trust boundary.** Elixir is the trusted, deterministic
substrate; Python is untrusted agent workload, quarantined behind the BEAM port. Nothing
in `lib/agent_os/` is agent code, and no agent code lives outside `agents/`.

- **Control plane:** Elixir ~> 1.20 on BEAM/OTP (`lib/agent_os/`) — kernel, gate,
  orchestration, scheduler, triggers. The elicitation orchestrator
  (`elicitation_session.ex`) is a substrate-side GenServer like everything else here.
- **Agent workloads:** sandboxed Python agents under `agents/<name>/`, run across the
  BEAM port boundary (`port_runner.ex`) — currently the discovery agent
  (`agents/discovery/`) and the elicitor agent (`agents/elicitor/`). Python appears
  *only* here. Shipped as deterministic stubs for tests.
- **Tests:** ExUnit, deterministic — no live LLM and no network in any test. The default
  host suite is hermetic (Docker-tagged tests excluded); the sandbox↔broker E2E tests run
  the substrate containerized inside the OrbStack VM (see below).

## Running the app

The substrate runs **only containerized** (spec 045). On macOS a Unix socket cannot cross the
host↔VM kernel boundary, so a host-run BEAM broker cannot be reached by sandboxed agents — a
host app start on macOS is therefore **refused loudly** (it names the container entry point). The
container is the one and only way to run everything: scheduler, triggers, generation, elicitation,
and the LiveView web UI.

```bash
docker compose build substrate          # build the containerized substrate (macOS + OrbStack)
docker compose up substrate             # THE way to run the app; UI at http://localhost:4000
```

`docker compose up substrate` starts the full app in the OrbStack VM (MIX_ENV=dev), with the
inference socket on the shared `aos_inf` named volume and the web UI published to the macOS host
at http://localhost:4000. For a real run reaching the model, the key is resolved from the
`MODEL_KEY` env var or the repo's `.env` (never committed).

## Running the suites

```bash
mix test                                # default hermetic host suite (no container needed)
docker compose run --rm e2e             # docker-tagged E2E suite in-VM (sandbox↔broker path)
```

The default host suite is hermetic and needs no container (autostart is disabled there, so the
boot guard never fires). The docker-tagged sandbox↔broker E2E tests run the substrate in the
OrbStack VM via the `e2e` compose service (MIX_ENV=test), sharing the inference socket with agent
containers over the `aos_inf` named volume. Details in
`specs/045-containerize-substrate-uds/quickstart.md`.

## Roadmap so far

Built incrementally as numbered specs under `specs/`:

1. **001 — Isolate the discovery agent**: run it contained, separate from the host.
2. **002 — Manifest enforcement**: declared permissions, enforced by the gate.
3. **003 — Manifest invisibility**: the agent cannot see its own policy.
4. **004 — Credential proxy**: the substrate holds keys and brokers them per-use.
5. **005 — Spend metering & real kill-on-breach**: per-agent budgets with a hard kill.
6. **006 — Dollar spend metering**: real dollars, metered at the inference chokepoint.
7. **007 — Event message triggers**: event-driven execution loops.
8. **008 — World-B verification**: verification pipeline for shadow workloads.
9. **009 — Capability render**: dynamic capability visualization.
10. **010 — Conformance auditor**: automated conformance auditing loop.
11. **011 — Review modes envelope**: human-in-the-loop deployment envelopes.
12. **012 — Elicit spec**: interactive specification eliciter.
13. **013 — Write manifest**: automated manifest generation.
14. **014 — Write judge**: automated judge synthesis.
15. **015 — Write novel agent**: automated code synthesis for custom agents.
16. **016 — Security review**: automated security validation static-analysis gates.
17. **017 — Deploy on green**: CI/CD automated promotion logic.
18. **018 — HTTP client OpenRouter**: native OpenRouter API integration.
19. **019 — Elicitor inference broker**: integration of elicitation workloads into inference broker.
20. **020 — Secure secret provisioning**: runtime environment credential isolation.
21. **021 — Token pricing sync**: dynamic API cost adjustment checks.
22. **022 — Elicitation UI**: LiveView elicitation console.
23. **023 — Consent screen UI**: human-in-the-loop deployment approval panel.
24. **024 — Standing inventory dashboard**: real-time control plane inventory dashboard.
25. **025 — Container privilege restriction**: Phase 7 container hardening, process limits, and memory/CPU resource limits.
26. **026 — Socket security permissions**: group-scoped inference socket access.
27. **027 — E2E generation thread**: end-to-end agent generation pipeline.
28. **028 — Pluggable connector registry**: connectors as declared, registered plugins.
29. **029 — Synchronous tools**: synchronous tool execution through the gate.
30. **030 — Connector admission**: admission control for connector plugins.
31. **031 — Approval flag split**: separated approval flags for distinct consent surfaces.
32. **032 — Queryable store**: queryable substrate state store.
33. **033 — Retire term file**: legacy term-file persistence retired.
34. **034 — Discord notify**: outbound Discord notification connector.
35. **035 — File connectors**: file read/append connectors.
36. **036 — Discord ingress**: inbound Discord message triggers.
37. **037 — Priorities coach generation**: generated priorities-coach agent.
38. **038 — Deterministic capability rails**: deterministic tool-call rails at the gate.
39. **039 — Run worker transcript migration**: transcript ownership moved to the rail.
40. **040 — Optional inference**: deterministic agents and the direct tool-call channel.
41. **041 — UI pipeline deploy**: generation pipeline surfaced in the UI.
42. **042 — Agent lifecycle controls**: pause, retire, and re-run controls.
43. **043 — Rerun checks**: re-runnable verification checks.
44. **044 — Sandbox generated agents**: generated agents run in the same container sandbox as config agents.
45. **045 — Containerize substrate**: substrate runs in-VM so the inference socket works cross-container on macOS.

Planning artifacts (spec, plan, tasks, contracts) for each live in
`specs/<NNN>-<name>/`. The binding principles live in
`.specify/memory/constitution.md`.
