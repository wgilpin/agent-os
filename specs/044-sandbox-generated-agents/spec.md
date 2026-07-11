# Feature Specification: Sandbox Generated Agents

**Feature Branch**: `044-sandbox-generated-agents`
**Created**: 2026-07-10
**Status**: Draft
**Input**: User description: "Generated agents must run inside the container sandbox (roadmap Phase 11, plan 11-01)."

## Overview

Machine-authored ("generated") agent bodies currently execute **outside** the container sandbox: the run worker dispatches them as a plain host interpreter process owned by the operator's OS user, with unrestricted filesystem access, open network, and no resource limits. The hand-written config/discovery agent, by contrast, runs inside a locked-down container. This inverts the intended trust posture — the code that cannot be audited (generated, and possibly prompt-injected into hostility) is the code with no runtime containment, while the trusted hand-written agent is the one that is jailed.

This feature routes generated agents through the **same** container sandbox as the config agent, so that no agent body — generated or hand-written — executes with ambient host authority. The only substrate layer that mediates a generated agent's non-Gate effects (filesystem, network, host processes) becomes the container boundary, closing the gap identified in the isolation threat model.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A generated agent runs jailed (Priority: P1)

The operator generates an agent from a stated purpose and it is deployed. When the substrate fires that agent on its trigger, the agent body executes inside a container with no network, a read-only root filesystem, dropped privileges, and a non-root user — the same containment the config agent already has — while still reaching the model and its granted tools through the inference channel exactly as before.

**Why this priority**: This is the entire point of the feature. Without it, every generated agent is unconfined host code. It is the minimum viable slice: one generated agent running correctly inside the sandbox delivers the security property.

**Independent Test**: Generate (or use an existing generated) agent, fire it, and confirm from the run record and container metadata that it executed via the container runtime (not a host interpreter), completed its reasoning, reached the model over the inference channel, and produced its normal output.

**Acceptance Scenarios**:

1. **Given** a deployed generated agent, **When** the substrate dispatches a production run for it, **Then** the agent body executes inside the container sandbox (network isolated, read-only root, non-root user, resource-limited) and never as a bare host interpreter process.
2. **Given** a generated agent running inside the sandbox, **When** it needs the model or a granted tool, **Then** it communicates over the inference channel with the same run token, socket, and model-selection behaviour it had before this feature, and the run succeeds.
3. **Given** the config/discovery agent and a generated agent, **When** each is dispatched, **Then** both run through the one shared sandbox path, differing only in which runtime image and which code directory are mounted.

---

### User Story 2 - Containment is proven against hostile code (Priority: P1)

A deliberately hostile generated agent body — the adversarial case the threat model says the sandbox must be sized for — attempts to read a host file outside its mounts, open an outbound network connection, and write outside its scratch space. All three attempts fail, and each failure is recorded loudly rather than passing silently.

**Why this priority**: A sandbox that is not adversarially tested is a claim, not a control. This is the regression guarantee that the containment actually holds, in the same spirit as the existing world-B enforcement suite. It must ship with User Story 1.

**Independent Test**: Run a containment probe: a hostile agent body that tries (a) reading a host path outside its mounts, (b) an outbound socket connection, and (c) a write outside the scratch area. Assert all three are refused and logged.

**Acceptance Scenarios**:

1. **Given** a hostile agent body attempting to read a host file outside its mounted code directory and the inference socket, **When** it runs in the sandbox, **Then** the read is denied.
2. **Given** a hostile agent body attempting to open an outbound network connection, **When** it runs in the sandbox, **Then** the connection is refused.
3. **Given** a hostile agent body attempting to write to any location other than the designated scratch space, **When** it runs in the sandbox, **Then** the write is denied.
4. **Given** any of the above containment failures, **When** it occurs, **Then** it is surfaced in a log or run record rather than being swallowed silently.

---

### User Story 3 - The bypass path cannot be reached in production (Priority: P2)

The substrate no longer has a production code path that dispatches a generated agent as an unconfined host process. The explicit-override mechanism used by the test suite and port harnesses still works, but production dispatch of a generated agent always goes through the sandbox.

**Why this priority**: Closing the hole is only durable if the hole is removed, not merely unused. This guards against a future change silently reintroducing the bypass. Lower than P1 because P1's acceptance already exercises the happy path; this is the "no back door" guarantee.

**Independent Test**: Inspect production dispatch behaviour for a generated agent name with no explicit command override and confirm it resolves to the container runtime; confirm the test-only explicit override still dispatches as directed.

**Acceptance Scenarios**:

1. **Given** a generated agent dispatched in production with no explicit command override, **When** the run worker builds the execution command, **Then** it is the container runtime, never a host interpreter.
2. **Given** a test or harness that passes an explicit command override, **When** it dispatches, **Then** that override is honoured unchanged.

---

### Edge Cases

- **Runtime image missing**: If the generated-agent runtime image is not present, the run must fail loudly with a clear cause (image unavailable), not fall back to an unconfined host process and not surface as an opaque non-zero exit.
- **Container runtime unavailable**: If the container runtime (daemon) is not running, the run fails loudly with a diagnosable message rather than silently doing nothing or bypassing the sandbox.
- **Generated agent needs its bundled dependencies**: A generated body that imports libraries the generator relies on (e.g. the data-validation library) must find them inside the container image, since the host interpreter and its environment are no longer used.
- **Agent code directory absent or unreadable**: If the agent's code directory cannot be mounted, the run fails with a clear cause rather than starting an empty or partial container.
- **Local-dev platform without native containers**: On the operator's development machine the container runtime runs inside its own virtualization layer; the feature must work there, and any platform limitation must fail loudly rather than degrade to an unconfined run.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Production dispatch of a generated agent MUST execute the agent body inside the container sandbox with the same containment properties applied to the config agent: network isolation (no network), read-only root filesystem, all Linux capabilities dropped, a non-root user, process/file-descriptor/memory limits, and a writable scratch area that does not persist to the host.
- **FR-002**: The substrate MUST provide a runtime container image for generated agents that includes the interpreter and the bundled dependencies a generated body requires, so that no host interpreter or host-installed dependency is used at runtime.
- **FR-003**: The substrate MUST mount the generated agent's code directory into the container **read-only**, so the agent can execute its body but cannot modify it or any other host code.
- **FR-004**: Config and generated agents MUST share a single sandbox execution path, differing only in the runtime image used and the code/mounts supplied — there MUST NOT be a separate, less-contained dispatch route for generated agents.
- **FR-005**: The production dispatch path MUST NOT contain any route that runs a generated agent as an unconfined host process. Removing this route is required, not merely avoiding it.
- **FR-006**: The substrate MUST retain the explicit command-override mechanism used by tests and harnesses; when an explicit override is supplied it is honoured, and only when no override is supplied does production dispatch default to the sandbox.
- **FR-007**: A generated agent running inside the sandbox MUST retain full use of the inference/tool channel: the run identity, the communication socket, and model selection MUST be injected into the container and function exactly as they do for the config agent today, and the inference socket MUST remain the sole writable host-backed mount.
- **FR-008**: The system MUST provide an automated adversarial containment probe demonstrating that a hostile generated body cannot (a) read host files outside its mounts, (b) open an outbound network connection, or (c) write outside the scratch area, and that each such attempt fails.
- **FR-009**: Every containment failure and every dispatch failure (missing image, unavailable runtime, unmountable code) MUST be surfaced loudly (logged and/or recorded in the run trace) with a diagnosable cause, never swallowed silently and never resolved by falling back to an unconfined run.
- **FR-010**: Existing enforcement guarantees (the world-B manifest-enforcement suite and the config agent's own sandboxed behaviour) MUST remain green — this feature adds containment for generated agents without weakening any existing containment or gate behaviour.

### Key Entities

- **Generated agent**: A machine-authored agent body deployed under its own name, distinct from the hand-written config/discovery agent. It is the subject of the new containment.
- **Generated-agent runtime image**: The container image supplying the interpreter and bundled dependencies for generated bodies, analogous to the config agent's image.
- **Sandbox execution path**: The single shared route that turns an agent + its mounts into a contained container invocation, now used by both config and generated agents.
- **Containment probe**: An adversarial test fixture — a hostile generated body plus assertions — proving the container denies host-file reads, outbound network, and out-of-scratch writes.
- **Inference/tool channel**: The existing communication path (run-token-identified socket) through which a sandboxed agent reaches the model and granted tools; must continue to work from inside the container.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of production generated-agent runs execute inside the container sandbox; zero run as an unconfined host process.
- **SC-002**: The adversarial containment probe demonstrates all three escape attempts (host-file read, outbound network, out-of-scratch write) are denied, and the probe is part of the automated suite so any regression fails the build.
- **SC-003**: A generated agent completes an end-to-end run from inside the sandbox — reaching the model over the inference channel and producing its normal output — with no loss of capability compared to before the change.
- **SC-004**: The existing enforcement suite (world-B) and the config agent's sandboxed behaviour remain fully green after the change.
- **SC-005**: Every failure mode (missing image, unavailable runtime, unmountable code, denied host operation) produces a diagnosable loud signal, and none is resolved by an unconfined fallback — verifiable by inducing each condition.

## Assumptions

- The existing container sandbox configuration used by the config agent (network none, read-only root, capability drop, non-root user, resource limits, scratch tmpfs, inference socket as sole writable mount) is the correct target posture for generated agents; this feature reuses it rather than defining a new one.
- The generated-agent runtime image is built from the same dependency set the generator assumes is available; keeping that image's dependencies in sync with what generated bodies import is part of this feature's delivery.
- On the operator's development machine, the container runtime executes inside its own virtualization layer, which is an acceptable host boundary for this phase; the acute gap being closed is agents running with *no* sandbox at all.
- The dedicated inference group/ownership alignment and the run-identity/socket/model environment injection already implemented for the config agent are the mechanism generated agents will reuse; no new inference-channel design is introduced here.
- Out of scope (deferred to later Phase 11 plans): the pluggable alternative-runtime knob (gVisor/runsc), the native per-agent-VM backend (Apple Containers), warm-pool spin-up optimisation, and trimming host file-sharing scope on the development machine (tracked as a separate operator task).
