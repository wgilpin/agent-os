# Feature Specification: Container Privilege Restriction

**Feature Branch**: `025-container-privilege-restriction`  
**Created**: 2026-07-01  
**Status**: Draft  
**Input**: User description: "Container Privilege Restriction (Phase 7 hardening; success criterion: 'Agent container execution drops privileges and isolates the host system')"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run Agent Safely without Host Privilege Escalation (Priority: P1)

As a system administrator, I want the agent container execution to run with dropped Linux capabilities and as a non-root user so that a compromised agent cannot escalate privileges or affect the host system.

**Why this priority**: Crucial first line of defense to prevent container escapes or host filesystem takeover.

**Independent Test**: Running the agent and checking that it fails to perform root-only operations (like modifying system files or executing system administration commands) and that it cannot elevate privileges.

**Acceptance Scenarios**:

1. **Given** a runner configuration with a non-root user, **When** the container is started, **Then** the container runs under the specified non-root uid and cannot gain root privileges.
2. **Given** a runner configuration trying to request a root user, **When** the sandbox arguments are constructed, **Then** the construction fails and execution is refused.

---

### User Story 2 - Prevent Resource and Process Exhaustion (Priority: P2)

As a system administrator, I want to prevent agents from launching fork-bombs or exhausting file descriptors so that a buggy or compromised agent cannot degrade the performance of the host system or other agents.

**Why this priority**: Prevents denial-of-service (DoS) attacks on the host.

**Independent Test**: Running an agent that initiates a fork bomb or attempts to open infinite files, verifying it is capped and does not impact other processes.

**Acceptance Scenarios**:

1. **Given** a running agent container, **When** it tries to create new processes beyond the process limit, **Then** further process creation fails, mitigating fork bomb attacks.
2. **Given** a running agent container, **When** it tries to open file descriptors beyond the file descriptor limit, **Then** further file creation/opening fails, mitigating resource exhaustion.

---

### User Story 3 - Restrict Network and Writable Volumes (Priority: P3)

As a security auditor, I want to guarantee that agent execution cannot access external networks and cannot bind arbitrary writeable host directories so that data exfiltration and host file tampering are prevented.

**Why this priority**: Hardens network and storage boundaries to guarantee isolation of agent code execution.

**Independent Test**: Running an agent and verifying network connections fail and that the only writable directory is the isolated in-memory scratch space.

**Acceptance Scenarios**:

1. **Given** a runner configuration requesting host network access, **When** sandbox arguments are generated, **Then** the execution is refused.
2. **Given** a runner configuration with a host volume mount that is not designated read-only, **When** sandbox arguments are generated, **Then** the execution is refused unless it is the single allowed communication socket.

---

### Edge Cases

- What happens when the agent tries to request memory or CPU limits above the designated ceilings?
- How does the system handle attempt to bypass read-only filesystem restrictions via nested directories?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The sandbox execution MUST unconditionally drop all Linux capabilities (`--cap-drop ALL`) and disable new privilege gains (`--security-opt no-new-privileges`).
- **FR-002**: The sandbox execution MUST run as a non-root user (uid 1000 or similar non-zero user) and reject any configuration specifying root user execution (uid 0/root).
- **FR-003**: The sandbox execution MUST restrict network interfaces to `none` and reject configurations trying to enable other network types.
- **FR-004**: The sandbox execution MUST enforce fixed CPU and Memory caps (ceilings), refusing execution configurations requesting resources above these limits.
- **FR-005**: The sandbox execution MUST limit total processes (fork-bomb protection) and open file descriptor limits to prevent host system exhaustion.
- **FR-006**: The sandbox execution MUST restrict writable host storage binds. Any host bind mount other than the dedicated communication socket MUST be mounted read-only.

### Key Entities *(include if feature involves data)*

- **Agent Sandbox Configuration**: Represents the execution parameters applied to the container, including image, capabilities, limits, network modes, user permissions, and host directory bindings.
- **Resource Ceilings**: Represents the upper limits of memory, CPU, process count, and open files allowed for any agent run.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Agent containers attempting to run with root user privileges are blocked from executing.
- **SC-002**: Agent containers attempting to open outbound network connections fail to resolve or connect to any host.
- **SC-003**: Agent containers executing a fork-bomb are restricted to under 32 processes, leaving the host system unaffected.
- **SC-004**: Agent containers attempting to write to the host filesystem outside the designated scratch space are blocked by a read-only filesystem error.

## Assumptions

- Agent execution does not require root/admin permissions for its tasks.
- The host system runs Docker or an equivalent container runtime supporting these standard isolation flags.
- Agents require less than 128MB of memory and 0.5 CPU cores to perform their tasks.
