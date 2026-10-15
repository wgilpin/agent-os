# Implementation Plan: Agent Runtime Kit (`agent_os_runtime`)

**Branch**: `046-agent-runtime-kit` | **Date**: 2026-07-12 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/046-agent-runtime-kit/spec.md`

## Summary

Ship `agent_os_runtime`, a first-party Python kit that wraps `pydantic-ai-slim[openai]==2.5.0` so generated agent bodies get `substrate_model()` + `run_agent()` instead of ~40 lines of hand-rolled AF_UNIX HTTP. The kit points pydantic-ai's OpenAI provider at the broker's mounted UDS via `httpx.AsyncHTTPTransport(uds=…)`, presenting the run token as the provider `api_key` (→ `Authorization: Bearer`). The broker gains a **single-turn** OpenAI-compatible surface (`POST /v1/chat/completions`) that authenticates on the Bearer token and maps onto the exact same pricing/metering/cap/kill path as the native `/v1/inference` envelope — the framework drives the tool loop client-side (in the untrusted body), the broker meters each discrete call. The native envelope path and all world-B invariants are untouched. Kit + framework are baked into `agents/generated.Dockerfile` at build time with exact pins, proven offline under `--network=none`.

**Architectural pivot from the native path**: `/v1/inference` runs the *entire* tool loop server-side (`do_complete_loop` recurses, executing manifest connector tools through `CapabilityRail`). The OpenAI surface does **not** — it is one metered completion per request; the framework in the body executes its own *plain in-body* tools (golden task) and calls back for the next turn. Connector-registry tool binding stays on the native/`/v1/tool_calls` channel and is out of scope (13-02). This keeps the trust boundary identical: the OpenAI surface adds no new gate authority, only a second wire format over the same meter.

## Technical Context

**Language/Version**: Elixir/OTP (control plane, broker) + Python 3.11 (kit + agent bodies, sandboxed workloads)
**Primary Dependencies**: `pydantic-ai-slim[openai]==2.5.0` (kit, exact pin), `httpx` (UDS transport, pulled transitively), `pydantic>=2.13` (existing); Elixir: `Req`/`Jason`/`:gen_tcp` (existing)
**Storage**: N/A new — spend ledger via existing `StateStore` single-writer GenServer; history is opaque JSON threaded through, never persisted by the kit (Phase 14 owns persistence)
**Testing**: `pytest` (Python kit suite, seeded from bake-off harness, no network) + `ExUnit` (Elixir E2E over the port boundary via `start_broker_uds!/1`) + `docker run --network=none` in-image containment probe
**Target Platform**: Single-user macOS host, OrbStack container runtime; broker on BEAM, bodies in the spec-044 generated-agent container
**Project Type**: Multi-language monorepo — Elixir substrate under `lib/agent_os/`, Python workloads under `agents/` + new first-party kit at repo root
**Performance Goals**: Not latency-bound; kit import delta ~0.19 s and ~37 MB image delta are immaterial per the bake-off. Correctness/containment are the goals, not throughput.
**Constraints**: Offline-total under `--network=none` (zero egress, no lazy tiktoken fetch); AF_UNIX `sun_path` ≤ ~104 chars on macOS (keep socket paths short); no framework feature that issues uncommanded calls (telemetry/background/direct-provider fallback) may be enabled; bounded visible retries (default 2)
**Scale/Scope**: One kit package (2 public functions), one new broker route + auth-header parse, one sample agent body (<30 lines), three test tiers, one Dockerfile edit

## Constitution Check

*GATE: evaluated against `.specify/memory/constitution.md` v1.3.0.*

| Principle | Status | Notes |
|---|---|---|
| I. Simplicity First | PASS | Kit is a thin wrapper (2 functions) over a proven framework; no new abstractions. The single-turn broker route reuses the existing pricing/meter/cap helpers rather than adding a parallel meter. Framework choice already settled empirically — not re-litigated. |
| II. Explicit Scope Control | PASS | Scope is exactly the kit + transport + one broker surface. Connector tool-stub codegen (13-02), Stage-4 generation (13-03), history persistence + chat routing (Phase 14) explicitly deferred. No "while I'm here" edits to gate/manifest. |
| III. Test-Driven Backend | PASS | Broker surface (backend logic) built test-first: broker-level ExUnit tests for auth/meter/cap/kill on the new route precede the route handler. Python kit transport/retry/history covered deterministically. |
| IV. No Live Dependencies in Tests | PASS | All three tiers use a stub/scripted broker (Elixir `provider_fn` stub; Python stub UDS broker from the bake-off harness). Zero live model calls. `--network=none` structurally forbids egress. |
| V. Strong Typing, No Bare Maps | PASS | Kit uses Pydantic models for payload/outcome/history; `mypy` clean; `ruff` clean. Elixir additions carry typespecs; Dialyzer clean. |
| VI. Loud Failures | PASS | Kit fails fast with a structured error outcome (never silent) on missing env, unreachable broker, malformed history, retry exhaustion (FR-009). Broker logs rejections (bad token, cap breach) as today. |
| VII. Self-Documenting | PASS | Every kit function carries a docstring; broker additions carry `@doc`/inline intent comments. |
| VIII. Legibility | PASS | Each metered call remains one discrete broker request in the log; the outcome record + run-log tally are unchanged in shape (outcome/reason), history delta is additive. |
| IX. Substrate Owns State & Lifecycle | PASS | Kit persists nothing; history is threaded in / delta out only. Bodies stay invocation-scoped pure functions (`run_sync` once, then exit). No agent-specific vocabulary enters `lib/agent_os/`. |
| X. No Ambient Authority | PASS | The kit runs inside the untrusted body and has **zero** enforcement authority — its typing is DX/early-failure only. The manifest stays gate-only. The Bearer token is the same per-run capability token already minted. |
| XI. Deterministic Gate Is the Only Firewall | PASS | The OpenAI surface adds a wire format, not a gate. It runs no LLM+credential fusion: the broker still holds the model key, the body never sees it (`MODEL_KEY` scrubbed at the port). Plain in-body tools cross no gate; connector tools (which do) are out of scope. |
| XII. Enforcement Precedes Generation | PASS | This is DX for generation (v3); enforcement (v2 gate/broker) already shipped and is unchanged. No reshuffle. |

**Gate result: PASS — no violations, Complexity Tracking not required.**

Post-design re-check (after Phase 1): still PASS. The design adds no gate surface, no manifest read by the agent, no new writable mount, and no persistence. See `research.md` §"Trust-boundary confirmation".

## Project Structure

### Documentation (this feature)

```text
specs/046-agent-runtime-kit/
├── plan.md              # This file
├── research.md          # Phase 0 — framework/transport/broker-surface decisions
├── data-model.md        # Phase 1 — payload, outcome+delta, OpenAI request/response, env contract
├── quickstart.md        # Phase 1 — how to run the three test tiers
├── contracts/
│   ├── openai-surface.md        # POST /v1/chat/completions request/response + auth + errors
│   └── kit-api.md               # substrate_model() / run_agent() signatures + payload schema
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
agent_os_runtime/                 # NEW — first-party kit (top-level, owned by repo, never generated)
├── __init__.py                   # exports substrate_model, run_agent
├── model.py                      # substrate_model(): UDS httpx client → OpenAIProvider → OpenAIChatModel
├── invoke.py                     # run_agent(): stdin payload → run_sync(message_history) → outcome+delta
├── schema.py                     # Pydantic models: InvocationPayload, OutcomeRecord (outcome/reason/history)
└── tests/                        # Python kit suite (pytest, no network)
    ├── conftest.py               # spins the stub UDS broker + AF_UNIX-only socket jail (seeded from harness/)
    ├── stub_broker.py            # adapted from .planning/bakeoff-agent-framework/harness/broker.py
    ├── socket_guard.py           # adapted from harness/socket_guard.py (AF_UNIX-only egress jail)
    ├── test_transport.py         # golden 2-tool task over UDS; env-contract resolution
    ├── test_retry.py             # malformed-args → bounded retries (default 2) → structured failure
    └── test_history.py           # history in → context threaded; delta out; malformed history fails fast

agents/
├── sample_kit_agent/             # NEW — golden reference body (<30 lines, zero transport/env code)
│   ├── main.py                   # imports agent_os_runtime; declares tools + typed output; run_agent(agent)
│   └── models.py                 # (if needed) typed output model
└── generated.Dockerfile          # EDIT — bake pydantic-ai-slim pin + COPY agent_os_runtime into /app

lib/agent_os/
└── inference_broker.ex           # EDIT — add /v1/chat/completions route, Bearer-token parse,
                                  #        single-turn metered complete_openai/2 (reuses pricing/ledger/cap)

test/agent_os/
├── inference_broker_openai_test.exs   # NEW — broker-level: auth/meter/cap/kill on the new surface
└── runtime_kit_e2e_test.exs           # NEW — sample body across the port boundary via start_broker_uds!/1

pyproject.toml                    # EDIT — add pydantic-ai-slim[openai]==2.5.0; register agent_os_runtime on path
uv.lock                           # EDIT (regenerated) — frozen resolution incl. the pin
```

**Structure Decision**: The kit is a **top-level package directory at the repo root** (`agent_os_runtime/`), not under `agents/` — it is first-party trusted DX code, distinct from the untrusted generated bodies under `agents/`. This mirrors the language/trust boundary in CLAUDE.md: `agents/<name>/` is untrusted workload; the kit is repo-owned. `PYTHONPATH=/app` in the image (and repo root in host tests) makes `import agent_os_runtime` resolve in both contexts. The broker change is confined to `inference_broker.ex` (one route + one metered function); no other `lib/agent_os/` file is touched.

## Complexity Tracking

> No Constitution violations — section intentionally empty.
