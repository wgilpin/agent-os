# Implementation Plan: Deterministic Capability Rails for Generated Agents

**Branch**: `038-deterministic-capability-rails` | **Date**: 2026-07-06 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/038-deterministic-capability-rails/spec.md`

## Summary

Retire the free-text LLM-to-LLM action protocol in the generation pipeline and route
every exact-string decision (connector id, method, model id) onto a deterministic
substrate rail. Concretely: (1) generated agents select actions **only** through the
broker's manifest-derived structured tool-call channel — the free-text `{"actions":[…]}`
JSON protocol is removed from the Stage-4 synthesis prompt and from generated bodies;
(2) the `InferenceBroker` gate rejects ungranted connectors **and** out-of-scope methods
deterministically, **records** rather than aborts on rejection, and gains a
**record-don't-execute** mode for judge evaluation; (3) a written **refusal contract**
defines a scoreable "no compliant action" outcome so adversarial probes yield pass/fail
verdicts, never infrastructure errors; (4) the substrate **owns model identity** (resolved
from config, not the workload's claim); (5) the judge is rescoped to semantic purpose-fit
and refusal-contract adherence, with deterministic rejections presented as observed facts.

The structured tool channel already exists in `InferenceBroker` (`build_tools_list/1`,
`execute_tool_calls/4`) but is currently bypassed because (a) generated agents run their
runtime inference under the **orchestrator's grant-less token**, so no tools are injected,
and (b) `discord_notify` and other manifest-reachable connectors carry no
`tool_declaration`. This feature closes those gaps and makes the structured channel the
sole runtime action path.

## Technical Context

**Language/Version**: Elixir ~1.16 / OTP 26 (control plane); Python 3.12 via `uv` (sandboxed workloads only)
**Primary Dependencies**: OTP GenServer/Task.Supervisor, `Req` (OpenRouter transport), `Jason`; PydanticAI on the Python side
**Storage**: single-writer `StateStore` term-file + git-backed append-only markdown (`RunLog`); no external DB
**Testing**: ExUnit; deterministic `provider_fn`/`runner_fn` seams — **no live model calls in tests** (Constitution IV)
**Target Platform**: local BEAM node; agent workloads across the port/UDS boundary (`port_runner.ex`, `INFERENCE_SOCKET`)
**Project Type**: single project (Elixir control plane + Python port workloads)
**Performance Goals**: not latency-bound; correctness/determinism of the gate is the goal
**Constraints**: gate rejections before any external effect; recorded-mode eval must produce **zero** external deliveries; spend metering semantics unchanged except non-executed recorded calls incur no connector cost
**Scale/Scope**: one end-to-end scenario (hello-world Discord) proven across ≥3 consecutive runs; the mechanisms must generalise to multi-grant manifests

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|-----------|------------|
| I. Simplicity First | **PASS** — reuses the existing tool channel and gate; adds a record mode flag, a method-scope check, a transcript store, and one config key. No new frameworks. Tool-per-connector kept (no per-method tool explosion). |
| II. Explicit Scope Control | **PASS** — every change traces to an FR. No "while I was here" work; connectors get `tool_declaration` only as needed to satisfy FR-014 for manifest-reachable grants. |
| III. Test-Driven Backend | **PASS** — all changed logic is Elixir control-plane; TDD red→green per task. |
| IV. No Live Dependencies in Tests | **PASS** — broker `provider_fn` and Stage-3 `runner_fn` seams drive deterministic tool-call and refusal fixtures. |
| V. Strong Typing, No Bare Maps | **PASS** — new structs for the action transcript, transcript entry, and refusal record; `Verdict.status` extended with `:malfunction`. |
| VI. Loud Failures | **PASS** — FR-014 turns the silent skip in `build_tools_list/1` into a raise; every deterministic rejection is logged and recorded. |
| VII. Self-Documenting | **PASS** — new functions/structs carry `@doc`/`@moduledoc`; the record-mode branch and method-scope gate are commented for intent. |
| VIII. Legibility | **PASS** — the action transcript is a standing, readable record of what each run did; strengthens legibility. |
| IX. Substrate Owns State & Lifecycle | **PASS** — transcript persisted via `StateStore` (single writer), keyed by run token; model identity resolved substrate-side. Agent-agnostic: no agent's domain concept enters `lib/agent_os/`. |
| X. No Ambient Authority | **PASS (central)** — the manifest becomes the sole source of the tool vocabulary; the workload can no longer name a connector, method, or model. Grants confer authority; the workload never self-confers. |
| XI. Deterministic Gate Is the Only Firewall | **PASS (central)** — enforcement stays in the broker gate; the judge is realigned as a smoke detector and explicitly stops re-answering grant questions. |
| XII. Enforcement Precedes Generation | **PASS** — v2 enforcement (the gate) already merged; this hardens generation (v3) on top of it. |

No violations. Complexity Tracking table omitted (nothing to justify).

## Project Structure

### Documentation (this feature)

```text
specs/038-deterministic-capability-rails/
├── plan.md              # This file
├── research.md          # Phase 0 — architecture decisions (transcript location, mode threading, model policy, method gate, refusal shape)
├── data-model.md        # Phase 1 — entities: ActionTranscript, TranscriptEntry, RefusalRecord, Verdict(+malfunction), ModelPolicy, ToolDeclaration
├── quickstart.md        # Phase 1 — how to run the hello-world Discord scenario end-to-end and verify SC-001..SC-006
├── contracts/
│   ├── tool-channel.md      # structured tool-call channel + deterministic gate contract (connector + method scope, record mode, rejection record)
│   └── refusal-contract.md  # the written refusal contract (FR-006) — the port-workload outcome shape
└── tasks.md             # Phase 2 (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/agent_os/
├── inference_broker.ex          # CHANGED: record-don't-execute mode; method-scope gate (FR-004); record-don't-abort rejections (FR-005);
│                                #          substrate-owned effective model (FR-012); loud failure on missing tool_declaration (FR-014);
│                                #          persist ActionTranscript per run token (FR-005, FR-010)
├── connector.ex                 # unchanged behaviour; `tool_declaration` already in the capability type
├── connector/
│   └── discord_notify.ex        # CHANGED: add `tool_declaration` + `execute_tool/2` (FR-002 channel, FR-014)
│                                #          (other manifest-reachable connectors get declarations only if a current manifest grants them)
├── pipeline/
│   ├── stage3_judge.ex          # CHANGED: register an agent-runtime record-mode token bound to the AGENT manifest; read the
│   │                            #          ActionTranscript as observed-actions (FR-009, FR-010); classify exit-status/refusal vs
│   │                            #          malfunction (FR-007); rescope synthesis + eval prompts to refusal contract & purpose-fit
│   │                            #          (FR-008, FR-013); `:malfunction` verdict status
│   └── stage4_agent.ex          # CHANGED: remove the free-text action protocol + AGENT_MODEL literal from the synthesis prompt;
│                                #          instruct the body to act via native tool calls and terminate with a refusal record (FR-001, FR-002, FR-006)
├── action_transcript.ex         # NEW: typed ActionTranscript / TranscriptEntry structs + StateStore-backed read/append/clear keyed by run token
└── run_worker.ex / provisioner  # touched only if the live (non-eval) runtime path needs the record-mode default; verified, minimal

agents/<hello-world-discord>/    # REGENERATED under the new protocol (not migrated) — asserted by FR-015/SC-005

test/agent_os/
├── inference_broker_test.exs        # method-scope rejection; ungranted-connector rejection is record-DON'T-abort (rejection recorded +
│                                    #   typed rejection tool message returned, loop not halted) (FR-003); record mode; rejection recording;
│                                    #   model override; missing-declaration raise; record-mode meters inference vs agent cap but charges NO
│                                    #   connector cost (FR-011); multi-grant manifest injects one declaration per grant + per-call rejection (edge)
├── action_transcript_test.exs       # NEW
├── pipeline/stage3_judge_test.exs   # refusal→pass; refusal-on-happy-path→fail; malfunction distinct from error; transcript-as-observed;
│                                    #   synthesized judge prompt references the refusal contract & has NO exact-string-reproduction pass
│                                    #   condition (FR-008, US5-AS1); monitored discord sink sees ZERO deliveries across a full eval run (SC-003)
├── pipeline/stage4_agent_test.exs   # no free-text protocol / no model literal in prompt or output; no manifest strings in body
├── connector/discord_notify_test.exs# tool_declaration present; execute_tool/2
└── world_b_generated_test.exs       # end-to-end regression for the retired protocol's absence
```

**Structure Decision**: Single Elixir project. All new trust-bearing logic lives under
`lib/agent_os/`; the only Python change is the regenerated agent body, produced by the
pipeline itself (not hand-written). One new module (`action_transcript.ex`) is justified
by Principle V (typed transcript over bare maps) and Principle IX (substrate-owned state).

## Complexity Tracking

> No Constitution violations — table intentionally empty.
