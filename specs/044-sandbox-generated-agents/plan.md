# Implementation Plan: Sandbox Generated Agents

**Branch**: `044-sandbox-generated-agents` | **Date**: 2026-07-10 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/044-sandbox-generated-agents/spec.md`

## Summary

Generated ("machine-authored") agent bodies currently execute **outside** the container
sandbox: `RunWorker.run_once/1` injects `agent_cmd: ".venv/bin/python"` for any agent whose
name ≠ the config agent, so a generated body runs as a bare host interpreter child of the
BEAM — the operator's macOS user, full filesystem, open network. This inverts the trust
posture (the un-auditable code is the unconfined code).

The fix routes generated agents through the **same** `AgentOS.Sandbox.build_argv/1` path
the config agent already uses. Concretely: (1) delete the direct-python dispatch branch in
`run_worker.ex`; (2) build a generic **generated-agent runtime image** (`agent-generated:dev`)
with the venv dependencies baked in and no agent code baked in; (3) mount `agents/<name>/`
into the container **read-only** and invoke the mounted `main.py`; (4) replace the
`cmd == "docker"` discriminator inside `execute_run/6` with a config-agent-identity check so
the config agent keeps its bookmark load + full `{state, items}` payload while generated
agents keep their `{roster}`+`trigger_input` payload; (5) add loud pre-flight failures for a
missing image, an unavailable runtime, or an unmountable code directory; (6) add a
world-B-style adversarial containment probe. The explicit `:agent_cmd` override that tests
and harnesses rely on is retained unchanged.

## Technical Context

**Language/Version**: Elixir ~1.17 / OTP 26 (control plane); Python 3.11 (sandboxed agent bodies)
**Primary Dependencies**: Erlang Ports (`PortRunner`), Docker CLI (`docker run`), `AgentOS.Sandbox` argv builder, `AgentOS.InferenceBroker` (UDS channel); Python `pydantic`, `google-genai` baked into the runtime image
**Storage**: term-file single-writer `StateStore` + git-backed markdown run-log (no DB); container scratch is a non-persistent `tmpfs`
**Testing**: ExUnit; docker-dependent tests carry `@tag :docker` and are **excluded by default** (`test/test_helper.exs` → `ExUnit.start(exclude: [:docker])`)
**Target Platform**: Linux containers via Docker; on the operator's macOS dev machine Docker Desktop's Linux VM is the host boundary
**Project Type**: Single project — Elixir substrate under `lib/agent_os/`, Python workloads under `agents/<name>/`
**Performance Goals**: N/A (correctness/containment feature; per-run container cold-start is acceptable — warm-pool is deferred to 11-04)
**Constraints**: No agent body may run with ambient host authority; every failure mode must be loud and diagnosable (Constitution VI); no new inference-channel design
**Scale/Scope**: One shared sandbox dispatch path for both config and generated agents; ~1 Elixir module touched (`run_worker.ex`), 1 new Dockerfile, 1 new probe test, config keys, docs

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Assessment |
|-----------|------------|
| **I. Simplicity First** | ✅ Reuses the existing `Sandbox.build_argv/1` path rather than a new mechanism; the generated image reuses the discovery Dockerfile pattern minus baked code. No new abstraction. Pluggable-runtime knob (11-03) and Apple Containers (11-04) are explicitly deferred. |
| **II. Explicit Scope Control** | ✅ Scope is exactly FR-001…FR-010. Deferred items (runsc knob, VM backend, Docker file-sharing trim, warm pool) are named out-of-scope in the spec. |
| **III. Test-Driven Backend** | ✅ Backend Elixir change (`run_worker` dispatch) is test-first; the containment probe is the world-B-style adversarial regression. |
| **IV. No Live Dependencies in Tests** | ✅ Docker is not a remote API; docker tests are `@tag :docker` and excluded from the default run. The inference broker remains the deterministic stub used by existing world-B tests. |
| **V. Strong Typing** | ✅ `%AgentOS.Sandbox{}` struct + typespecs already exist; new dispatch fields keep typespecs. No bare maps introduced. |
| **VI. Loud Failures** | ✅ FR-009 **is** this principle: pre-flight image/runtime/mount checks log at `:error` and record a diagnosable `failure_cause` in the run-log; **never** fall back to an unconfined run. |
| **VII. Self-Documenting** | ✅ New/changed functions carry purpose docstrings; the dispatch discriminator and pre-flight get intent comments. |
| **VIII. Legibility** | ✅ Every dispatch outcome (success + each failure mode) lands in the run-log with cause. |
| **IX. Substrate Owns State & agent-agnostic** | ✅ The generated image name and mount path are generic (`agent-generated:dev`, `/app/agents/<name>`), keyed off the manifest-derived agent name — no single agent's domain vocabulary enters `lib/agent_os/`. |
| **X. No Ambient Authority** | ✅ This is the point: closes the ambient-authority hole for generated bodies. Manifest stays gate-only; nothing new crosses the boundary. |
| **XI. Deterministic Gate Is the Only Firewall** | ✅ Runtime containment sits **below** the gate; authority mediation is unchanged. |
| **XII. Enforcement Precedes Generation** | ✅ Enforcement (world-B) already shipped and must stay green (FR-010); this hardens the runtime beneath it. |

**Result: PASS — no violations, Complexity Tracking not required.**

## Project Structure

### Documentation (this feature)

```text
specs/044-sandbox-generated-agents/
├── plan.md              # This file
├── research.md          # Phase 0 — key decisions
├── data-model.md        # Phase 1 — dispatch entities & fields
├── quickstart.md        # Phase 1 — build image + run + probe
├── contracts/
│   └── dispatch.md       # Phase 1 — the shared sandbox dispatch contract
├── checklists/
│   └── requirements.md   # (pre-existing)
└── tasks.md             # Phase 2 — /speckit-tasks (NOT created here)
```

### Source Code (repository root)

```text
lib/agent_os/
├── run_worker.ex         # CHANGED: delete direct-python branch; config-vs-generated
│                          #          image/mount/entrypoint selection; config-agent-identity
│                          #          discriminator; loud pre-flight failures
└── sandbox.ex            # UNCHANGED argv builder (already enforces the containment posture);
                           #          reused verbatim by generated agents

agents/
├── discovery/Dockerfile  # UNCHANGED (config-agent image `agent-discovery:dev`)
└── generated.Dockerfile  # NEW: generic runtime image `agent-generated:dev` — venv deps baked,
                           #      no agent code baked, no agent-specific ENTRYPOINT

config/
└── config.exs            # NEW keys: :agent_image (config agent), :generated_agent_image

test/agent_os/
├── generated_containment_test.exs   # NEW: @tag :docker adversarial probe (FR-008 / US2)
├── run_worker_transcript_test.exs   # may extend: production generated dispatch → docker (US3)
├── isolation_test.exs               # reference pattern for the probe
├── world_b_test.exs                 # must stay green (FR-010)
└── world_b_generated_test.exs       # must stay green (FR-010)

docs/
└── threat-model-agent-isolation.md  # append: generated agents now sandboxed (status note)
```

**Structure Decision**: Single-project Elixir substrate + Python workloads. The entire
behavioural change is concentrated in `run_worker.ex`'s command-building logic; `sandbox.ex`
is reused unchanged because it already encodes the required containment posture and its
mount/user/network invariants. The only new build artifact is one Dockerfile.

## Phase 0 — Research

See [research.md](research.md). Decisions resolved:

1. **Dedicated generic image** `agent-generated:dev` — deps baked, agent code mounted read-only (not baked). Reuses the discovery Dockerfile pattern minus `COPY agents/` and the discovery `ENTRYPOINT`; `run_worker` overrides `--entrypoint /app/.venv/bin/python` + `cmd_args ["/app/agents/<name>/main.py"]`.
2. **Import semantics preserved** — generated bodies use bare `from models import …`; invoking `python /app/agents/<name>/main.py` puts `/app/agents/<name>` on `sys.path[0]`, so the mounted leaf directory is sufficient. `PYTHONPATH=/app` is retained for parity.
3. **Discriminator refactor** — replace the four `cmd == "docker"` branches in `execute_run/6` (bookmark load + full payload) with a `config_agent?` boolean, so containment does not accidentally hand generated agents the config agent's bookmark payload.
4. **Loud failure strategy** — pre-flight `docker image inspect <image>` (classifies image-missing vs daemon-down from stderr) and `File.dir?("agents/<name>")` before dispatch; each failure logs at `:error` and writes a distinct `failure_cause` to the run-log; no host-python fallback (the branch that enabled it is deleted).
5. **Test gating** — the containment probe is `@tag :docker`, `async: false`, modelled on `isolation_test.exs`; excluded from default CI, run locally where Docker is present.

## Phase 1 — Design & Contracts

- **[data-model.md](data-model.md)** — the dispatch decision inputs (agent name, config-agent name, explicit override, image, mounts, entrypoint) and the run-log failure vocabulary.
- **[contracts/dispatch.md](contracts/dispatch.md)** — the single shared sandbox dispatch contract: given an agent + override state, what argv/mounts/image result, and what each failure mode records.
- **[quickstart.md](quickstart.md)** — build the generated image, run a generated agent jailed, run the containment probe.

**Agent context update**: `CLAUDE.md` SPECKIT marker repointed to this plan.

## Complexity Tracking

> No Constitution violations — table intentionally empty.
