# Feature Specification: Containerize the Substrate for Cross-Container Inference

**Feature Branch**: `045-containerize-substrate-uds`
**Created**: 2026-07-11
**Status**: Draft
**Input**: User description: "Containerize the substrate (BEAM) so the inference UDS works on macOS — run the substrate as a container in the same VM as the agents, with the inference socket on a shared named volume mounted into both sides. Full analysis in docs/substrate-containerization-analysis.md."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Sandboxed agent reaches the model (Priority: P1)

An operator on macOS deploys an agent (config or generated). The agent runs inside its sandbox with no network, and its only channel to the model is the substrate's inference socket. Today that connection is refused because the substrate listens on the macOS host while the agent runs inside the container VM. After this feature, the substrate runs alongside the agents in the same VM and the agent's inference calls succeed.

**Why this priority**: This is the entire point of the feature — without it, every sandboxed agent on macOS is correctly jailed but functionally dead (cannot reach the model). Spec 044's SC-003 has never been verifiable end-to-end on macOS.

**Independent Test**: Start the containerized substrate, dispatch a real generated agent, and observe it complete a run that includes at least one successful model call from inside its sandbox.

**Acceptance Scenarios**:

1. **Given** the substrate is running containerized with the shared inference volume, **When** a generated agent is dispatched, **Then** the agent connects to the inference socket and receives a model completion (no connection-refused error).
2. **Given** the substrate is running containerized, **When** the config agent is dispatched, **Then** it reaches the broker over the same shared-volume socket (parity between config and generated agents is preserved).
3. **Given** an agent container running as the standard non-root user, **When** it opens the inference socket, **Then** the connection is permitted (socket ownership/permissions allow the agent's group) while other users/processes without that group are not granted access.

---

### User Story 2 - Docker-tagged inference E2E tests pass (Priority: P2)

A developer runs the docker-tagged test suite on macOS. The suite currently cannot exercise the sandbox↔broker path because the test substrate runs on the host. After this feature, a documented invocation runs the suite with the substrate in-VM, and the inference E2E tests (hostile-web isolation test plus a generated-agent broker E2E) pass.

**Why this priority**: Without a passing E2E, the P1 behaviour cannot be regression-protected; this is the proof harness for the feature.

**Independent Test**: Run the documented docker-suite invocation and observe the inference E2E tests pass.

**Acceptance Scenarios**:

1. **Given** the containerized test entry point, **When** the docker-tagged suite runs, **Then** the hostile-web isolation E2E and a generated-agent broker E2E pass.
2. **Given** a per-test broker socket created by the test harness, **When** an agent container is dispatched by that test, **Then** the agent can reach that specific test's socket (tests remain isolated from each other).

---

### User Story 3 - Host test workflow unchanged; host app start refused (Priority: P3)

A developer continues day-to-day test work on the host (`mix test`, unit tests, non-docker suites) without any new container requirement. But *running the app* on the macOS host is no longer a mode at all: an attempted host start is refused loudly with a pointer to the container entry point, so nobody can accidentally operate a substrate whose agents cannot reach the broker.

**Why this priority**: Protects the existing development loop while eliminating the broken half-topology (host-run substrate with dead agents) as an operable state.

**Independent Test**: Run the default host test suite (green, no container involvement); attempt a host app start on macOS and observe a refusal with a clear message.

**Acceptance Scenarios**:

1. **Given** a fresh checkout on the host, **When** the default test suite runs, **Then** all tests pass with no requirement for the substrate container (docker-tagged tests remain excluded by default).
2. **Given** a macOS host, **When** an operator attempts to start the substrate application outside the container (e.g. `iex -S mix` with autostart), **Then** startup is refused with a loud, diagnosable message naming the container entry point — it must not come up half-working.
3. **Given** the host-bind socket topology in unit tests (autostart disabled), **Then** existing behaviour (bind path, 0700 directory, existing sandbox mount validation) is preserved for test purposes.

---

### User Story 4 - Operate the full substrate, including the web UI, from the container (Priority: P2)

An operator starts the substrate with a single documented command and gets everything: scheduler, triggers, generation pipeline, elicitation, and the web UI reachable from the macOS browser. The containerized substrate is the one and only way to run the app.

**Why this priority**: If the container mode cannot do everything the host mode did (above all the UI), operators are forced back into the refused host mode and the single-mode goal collapses.

**Independent Test**: Start the substrate via the documented command, open the UI from the macOS browser, complete a live UI interaction, and run an elicitation session — all against the containerized substrate.

**Acceptance Scenarios**:

1. **Given** the substrate started via the documented single command, **When** the operator opens the UI from the macOS browser, **Then** pages load and live (websocket-backed) interactions work.
2. **Given** the containerized substrate, **When** an elicitation session runs, **Then** the elicitor workload executes in-container and completes as it did on the host.
3. **Given** the containerized substrate, **When** state is written (rosters, ledgers, run logs), **Then** it persists to the same repo-local data files the host workflow used (survives container restarts).

### Edge Cases

- What happens when the shared inference volume exists but the substrate has not yet created the socket when an agent starts? The agent's connection fails loudly with a diagnosable error (Constitution VI), not a silent hang.
- What happens when the substrate container cannot set group ownership on the socket (misconfigured GID)? Startup fails loudly with the GID and reason in the log, as today.
- How does the system behave if the shared volume is mounted but a stale socket file from a previous run is present? The broker removes/rebinds as it does today (`File.rm` before listen).
- What happens when the repo is mounted into the substrate container at a *different* absolute path than on the host? Generated-agent code mounts (host-path-derived) would break; the setup must fail loudly or document the identical-path requirement.
- What if an agent attempts to write elsewhere on the shared volume beyond the socket? The volume is the sole writable mount by design; the sandbox invariant must state and enforce this boundary.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The substrate MUST be runnable as a container in the same kernel/VM as the agent containers, with the inference socket placed on a shared named volume mounted into both the substrate container and every agent container at the same path.
- **FR-002**: A sandboxed agent (config or generated, non-root user) MUST be able to connect to the inference broker socket and complete a model call when the substrate runs containerized.
- **FR-003**: The shared-volume topology MUST be the sole mode for a running substrate; the host-bind topology remains only for the hermetic host test suite (autostart disabled), where existing behaviour is unchanged.
- **FR-004**: In shared-volume mode, the agent dispatch MUST mount the shared volume (not a host file path) as the inference channel, and the agent's socket-path environment MUST point at the in-volume socket path.
- **FR-005**: The sandbox argv validation MUST enforce, in shared-volume mode, that the shared inference volume is the sole writable mount (all other mounts read-only), and retain the existing host-path equality check in host-bind mode.
- **FR-006**: In shared-volume mode, the broker MUST make the socket reachable by the agent's configured inference group while excluding others (group-accessible socket directory and socket; owner-only directory permissions remain the rule in host-bind mode).
- **FR-007**: The substrate container MUST be able to dispatch sibling agent containers via the container daemon, and host-path-derived read-only code mounts for generated agents MUST remain valid (repo visible inside the substrate container at the identical absolute path).
- **FR-008**: There MUST be a documented, repeatable entry point to run the docker-tagged test suite with the substrate in-VM, and the per-test broker sockets created by the test harness MUST be reachable from agent containers dispatched by those tests.
- **FR-009**: Failures in the new topology (socket absent, permission denied, volume missing, daemon unreachable) MUST fail loudly with a diagnosable cause — never silently and never by falling back to a host run.
- **FR-010**: Dispatch behaviour introduced by spec 044 MUST be unchanged except for the inference-socket mount source and socket path (config/generated parity per 044 FR-007 preserved).
- **FR-011**: The substrate MUST refuse to start its application supervision tree on the macOS host (outside the container), failing loudly with a message that names the container entry point; test runs (autostart disabled) are unaffected.
- **FR-012**: The containerized substrate MUST expose the web UI to the host browser, including live (websocket-backed) views, via a single documented start command.
- **FR-013**: All substrate functions MUST work containerized — scheduler/triggers, the generation pipeline, elicitation (its workload runs in-container), and repo-local state persistence across container restarts.

### Key Entities

- **Shared inference volume**: A named volume owned by the substrate deployment, mounted at one agreed path in the substrate container and every agent container; holds only the inference socket (and per-test sockets under the test harness).
- **Socket topology mode**: A configuration state — `shared-volume` (substrate containerized, volume mount) or `host-bind` (current behaviour, host file path bind).
- **Substrate container**: The containerized BEAM application, holding the broker listener, the container-daemon access for sibling dispatch, and the repo mounted at its host-identical path.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A real generated agent completes a run on macOS that includes at least one successful model call from inside its sandbox (spec 044 SC-003, now verifiable).
- **SC-002**: The docker-tagged inference E2E tests (hostile-web isolation test and a generated-agent broker E2E) pass with the substrate containerized, via a single documented command.
- **SC-003**: The default host test suite passes unchanged, with zero new host-side requirements for developers who do not run docker-tagged tests.
- **SC-004**: With no shared volume configured, observable behaviour of the substrate and sandbox is byte-for-byte identical to pre-feature behaviour (existing suites prove this).
- **SC-005**: An agent process outside the configured inference group cannot connect to or read the socket in shared-volume mode.
- **SC-006**: One documented command starts the full substrate, and the operator can open the UI from the macOS browser and complete a live interaction against it.
- **SC-007**: Attempting to start the substrate app on the macOS host fails immediately with a message pointing at the container entry point (no half-working host substrate is reachable).

## Assumptions

- macOS with OrbStack is the only target platform for the shared-volume mode; the container-to-container UDS topology was empirically proven there (two containers sharing a socket volume connect; non-root uid 1000).
- The identical-absolute-path repo mount inside the substrate container is achievable on OrbStack (host paths are visible to the VM), making sibling-container code mounts valid without path translation.
- Group-ownership changes on the socket succeed inside a Linux container (the previously observed permission failure was a macOS-host limitation).
- Roadmap 11-04 (per-agent hardware VMs, vsock) is out of scope; this feature is plain container-to-container UDS.
- No change to generation, judging, or spend semantics — this feature is purely about where the substrate runs and how the socket is shared.
