# Implementation Plan: Stage 4 Write the Novel Agent Body (write-novel-agent)

**Branch**: `015-write-novel-agent` | **Date**: 2026-06-30 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/015-write-novel-agent/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command. See `.specify/templates/plan-template.md` for the execution workflow.

## Summary

Stage 4 synthesises a novel, sandboxed Python/PydanticAI agent body — `agents/<agent_name>/main.py`
plus its typed `models.py` — from exactly two inputs: the confirmed purpose string and the
machine-written `AgentOS.Manifest` struct Stage 2 (`AgentOS.Manifest.Projection`) emitted. It is an
Elixir module, `AgentOS.Pipeline.Stage4`, that mirrors the established Stage 3
(`AgentOS.Pipeline.Stage3`) shape: one inference call routed through `AgentOS.InferenceBroker` (the
single metered chokepoint), a hard isolation guard that rejects any opt smuggling judge-spec or
elicitation-transcript context, a parse of the model's JSON-files response into typed structs, a set
of deterministic static guards over the generated source (no manifest/credential literals, no direct
provider host, Python syntax validity, presence of the typed stdin/stdout contract), and an
all-or-nothing write to disk. Any guard failure or broker failure fails closed: no partial files are
written and no fallback body is substituted.

## Technical Context

**Language/Version**: Elixir (OTP, existing project version) for the orchestration module; the
*emitted artifact* is Python 3.11 (matching `agents/discovery`'s `Dockerfile` base image)
**Primary Dependencies**: `AgentOS.InferenceBroker` (existing chokepoint), `Jason` (JSON
encode/decode, already a project dependency), `AgentOS.Manifest` / `AgentOS.CapabilityRender`
(existing structs/render used to build the synthesis prompt); emitted Python uses `pydantic`
(already vendored for `agents/discovery`, `agents/elicitor`) — no new dependency anywhere
**Storage**: Filesystem only — writes `agents/<agent_name>/main.py` and
`agents/<agent_name>/models.py`; no new StateStore collection (Stage 4 produces a file artifact,
not a result/verdict record, so there is nothing analogous to Stage 3's `judge_results` to persist)
**Testing**: ExUnit with a stubbed `provider_fn` (Constitution IV: no live model calls in tests),
mirroring `test/agent_os/pipeline/stage3_judge_test.exs`'s seam pattern; static-guard unit tests run
against fixture Python strings (good and adversarial) without invoking any subprocess for those
cases, plus one guard that does shell out to `python3 -m py_compile`/`ast.parse`-equivalent for
syntax validity, exercised in tests via real but trivial fixed source strings (no network, no model)
**Target Platform**: Server-side Elixir/OTP process (control plane), emitting a workload that later
runs inside the existing Linux/Docker sandbox (`agents/discovery/Dockerfile` pattern)
**Project Type**: Single Elixir/OTP application with sandboxed Python port workloads (existing
structure; Stage 4 adds one orchestration module and a static-guard helper, no new app/service)
**Performance Goals**: Not a performance-sensitive path — one inference call per generation,
bounded by the broker's existing timeout/spend-cap handling; no explicit new goal beyond "does not
hang" (broker call has the same opts-driven timeout seam Stage 3 uses)
**Constraints**: Must hold no model credential and open no second provider path (FR-009); must
verify the body before writing rather than after (FR-011); must fail closed on any guard or broker
failure with no partial write (FR-012); must not read `judge_spec.json` under any code path (FR-003)
**Scale/Scope**: One Stage-4 run per agent generation; output is two small Python files (tens to a
few hundred lines), not a service expected to handle concurrent load

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Check | Status |
|---|---|---|
| I. Simplicity First | One new Elixir module (`Stage4`) + one static-guard helper, reusing `InferenceBroker`, `Jason`, existing manifest/capability-render structs. No new dependency, no new service, no new StateStore collection. | PASS |
| II. Explicit Scope Control | Scope is exactly the spec's 13 FRs: synthesize, isolate from judge, typed contract, no-manifest-leak, no-direct-provider, single chokepoint (both calls), fail-closed, no run/deploy/security-review. No inventory rendering, no gate change, no deploy wiring added — those are out of scope per spec and not pulled in. | PASS |
| III. Test-Driven Backend | `AgentOS.Pipeline.Stage4` is backend control-plane logic → TDD red/green/refactor, mirroring `stage3_judge_test.exs`'s structure. | PASS (enforced at /speckit-tasks) |
| IV. No Live Dependencies in Tests | All inference is via a stubbed `provider_fn` (the same seam `InferenceBroker.complete/2` already exposes for Stage 3's tests). No test calls a real model or a real Python subprocess that does anything beyond a local syntax parse. | PASS |
| V. Strong Typing, No Bare Maps | Elixir side: `AgentOS.Pipeline.Stage4.GeneratedFile` / `AgentOS.Pipeline.Stage4.AgentBody` structs with `@enforce_keys` + `@type`, no bare maps crossing the public API (mirrors `Stage3.TestSpec`/`TestCase`). Python side: FR-004 requires the emitted body itself use Pydantic models for stdin input and proposed-action output — this is asserted by a static guard, not assumed. | PASS |
| VI. Loud Failures | Every guard failure and broker failure returns a tagged `{:error, reason}` and is logged with context (mirrors Stage 3's `Logger` use around broker/parse failures); no exception is swallowed silently. | PASS (enforced at /speckit-tasks) |
| VII. Self-Documenting Through Comments | `@moduledoc`/`@doc` on the new module and every public function; non-obvious guard logic (e.g. the manifest-literal scan) gets an inline comment explaining intent. | PASS (enforced at /speckit-tasks) |
| VIII. Legibility | Not a standing-inventory concern by itself — Stage 4 produces a file artifact, and FR scope deliberately excludes wiring it into the inventory (that would be new scope; see II). No legibility regression: failures are logged loudly per VI. | PASS (no new opacity introduced) |
| IX. Substrate Owns State & Lifecycle | No new persistent store; the only mutation is the filesystem write of the two agent files, performed by the calling process (no new GenServer, no new single-writer needed — file write is the existing pattern `Stage3.generate/3` already uses for `judge_spec.json`). Substrate stays agent-agnostic: `agent_name` is a parameter, never hard-coded. | PASS |
| X. No Ambient Authority | The emitted body is given no manifest, no caps, no credential — by construction (FR-006/007/008), checked structurally before write (FR-011). Stage 4 itself only *reads* the manifest to build the prompt; it never grants anything. | PASS |
| XI. The Deterministic Gate Is the Only Firewall | Stage 4 introduces no new privileged-action path; the emitted body proposes actions to the substrate exactly as `agents/discovery` does today, to be validated by the existing gate (unchanged). Stage 4's own static guards are a smoke detector on the generated *code*, not a runtime enforcement mechanism, and are described as such. | PASS |
| XII. Enforcement Precedes Generation | Already satisfied at the roadmap level (v2 complete before v3); Stage 4 does not touch the gate. | PASS |

No violations to record in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/015-write-novel-agent/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md         # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   └── agent-generator-api.md
└── tasks.md              # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
lib/agent_os/
└── pipeline/
    └── stage4_agent.ex          # NEW — orchestration module (generate/3 + static guards)

test/agent_os/
└── pipeline/
    └── stage4_agent_test.exs    # NEW — ExUnit tests, stubbed provider_fn

agents/
└── <agent_name>/                 # WRITE TARGET (per-run, not committed by this feature)
    ├── main.py                   # emitted by Stage 4 at generation time
    └── models.py                 # emitted by Stage 4 at generation time
```

**Structure Decision**: Single Elixir/OTP project (existing layout, no new app). Stage 4 is one new
module under `lib/agent_os/pipeline/`, parallel to the existing `lib/agent_os/pipeline/stage3_judge.ex`,
with its test under the matching `test/agent_os/pipeline/` path. It writes into the existing
`agents/<agent_name>/` convention already used by `agents/discovery/` and `agents/elicitor/` — no new
top-level directory. No `frontend/`/`backend/` split applies; this is server-side control-plane code
with a Python emission target, the same shape Stage 3 already established.

## Complexity Tracking

> No Constitution Check violations — table not applicable.
