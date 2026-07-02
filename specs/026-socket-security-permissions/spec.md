# Feature Specification: Socket Security & Permissions

**Feature Branch**: `026-socket-security-permissions`  
**Created**: 2026-07-02  
**Status**: Draft  
**Input**: User description: "/speckit-specify Implement roadmap plan 07-02 — Socket Security & Permissions: harden the inference Unix-domain socket so OS-level access control (not just the application-layer run-token) protects the substrate's inference chokepoint, and minimize what the sandboxed container can see through its mounts so the host OS is protected. This is the final Phase 7 (Hardening & Sandbox) plan; Phase 7 success criterion 2: \"Unix socket communication is secured via runtime constraints.\""

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Secure Host Socket Layer (Priority: P1)

As the system administrator / substrate host, I want the Unix-domain socket at `data/inference.sock` to be protected by OS-level permissions (mode `0660` and owned by a dedicated GID) so that arbitrary local processes on the host cannot open the socket or connect to it, ensuring only the substrate broker and authorized GID-aligned agents can communicate.

**Why this priority**: Establishing foundational OS-level access control is the main goal of the hardening roadmap plan to protect the substrate's inference chokepoint.

**Independent Test**: Can be verified by running the broker, checking that `data/inference.sock` has permissions set to `0660` and the configured group owner GID, and asserting that a connection attempt from a local host process running under a different, non-member GID fails immediately with `Permission Denied` (EACCES) before any application-level handshake or token authentication occurs.

**Acceptance Scenarios**:

1. **Given** the inference broker starts up, **When** the Unix-domain socket file at `data/inference.sock` is created, **Then** the broker must set the file's permissions to `0660` (read/write for owner and group, none for others) and change the group ownership to the configured dedicated inference GID.
2. **Given** a local process running as a user who is neither the broker owner nor a member of the dedicated inference GID group, **When** it attempts to connect to `data/inference.sock`, **Then** the connection attempt fails at the OS socket layer with a permission error.

---

### User Story 2 - GID-Aligned Agent Inference (Priority: P1)

As a sandboxed agent container, I want to be launched with membership in the dedicated inference group so that I can successfully connect to the mounted inference socket and execute inference rounds using the run-token.

**Why this priority**: The legitimate sandboxed agents must continue to function correctly under the new socket security constraints.

**Independent Test**: Can be verified by running the container integration tests (`test/agent_os/sandbox_test.exs`) with GID alignment enabled, ensuring the agent process inside the container can connect to `/tmp/inference.sock` and successfully complete an inference round-trip.

**Acceptance Scenarios**:

1. **Given** the sandbox launches an agent container, **When** it configures the container execution using GID alignment matching the dedicated inference GID, **Then** the agent's process inside the container is able to connect to the mounted socket at `/tmp/inference.sock`.
2. **Given** the agent has connected to `/tmp/inference.sock`, **When** it sends an inference request with the correct `RUN_TOKEN`, **Then** the substrate broker accepts the request and returns the inference result.

---

### User Story 3 - Restricted Parent Directory Access (Priority: P2)

As the system administrator, I want the directory containing the socket (`data/`) to have restricted permissions (mode `0700`, owner-only) so that unauthorized local processes cannot perform path traversal or directory listing to inspect or access files in the `data/` directory.

**Why this priority**: This prevents directory-listing bypasses and secures the environment surrounding the socket, acting as a secondary layer of protection.

**Independent Test**: Can be verified by verifying that another host user cannot list the contents of the `data/` directory or traverse into it.

**Acceptance Scenarios**:

1. **Given** the inference broker starts up, **When** the broker initializes the directory containing the socket, **Then** the directory permissions are set to `0700` (read, write, search by owner only), blocking listing or traversal by other host users.

---

### User Story 4 - Minimized Mount Surface (Priority: P2)

As the system administrator, I want the sandbox container mounts to be minimized such that only the specific socket file itself (`data/inference.sock`) is mounted as a file, rather than mounting the parent `data/` directory or other host paths, minimizing the attack surface exposed to the container.

**Why this priority**: On macOS/Docker Desktop, the hypervisor file sharing layer bridges access, and minimizing mounts is the main lever to protect the host OS.

**Independent Test**: Can be verified by inspecting the docker run arguments generated by the Sandbox runner to verify that only the socket file path is mounted, and by checking from within the container that no other host paths or directories are visible/writable.

**Acceptance Scenarios**:

1. **Given** the sandbox launches an agent container, **When** the mount configuration is generated, **Then** only the individual socket file `data/inference.sock` is mounted at `/tmp/inference.sock`, and no parent directories or other writeable host paths are exposed.

---

### User Story 5 - Fail-Secure Socket Lifecycle (Priority: P1)

As the system administrator, I want the socket lifecycle to fail secure, meaning that if the broker cannot apply the restrictive ownership/permissions (e.g. invalid GID or missing permissions to chown/chmod), the broker must refuse to serve and shut down rather than starting up with insecure permissions.

**Why this priority**: Allowing fallback to insecure defaults violates the Constitution (Constitution VI — loud failure) and compromises the security guarantee.

**Independent Test**: Can be verified by configuring an invalid GID or forcing chmod/chown to fail, and verifying that the broker crashes or refuses to start.

**Acceptance Scenarios**:

1. **Given** the broker starts up, **When** a permission change or group ownership change on the socket fails, **Then** the broker fails loudly, logs the error, and terminates.

### Edge Cases

- **Stale Socket Handling**: If a stale socket file exists at `data/inference.sock` upon startup, it must be deleted first, and the new socket must be created directly with the restricted permissions or quickly protected without a race condition window where it is world-writable.
- **Mounting a Non-existent/Deleted Socket**: If the host socket file is deleted/recreated during agent runtime, Docker Desktop bind-mounts of individual files do not automatically update if the host file is unlinked and recreated. The broker and sandbox must coordinate to ensure the socket lifecycle aligns with the container lifecycle.
- **macOS Docker Desktop Soft DAC Enforcement**: On macOS Docker Desktop, DAC permission bits are only softly enforced across the VM boundary. The run-token remains the primary authority for container authentication, while the socket permission model acts as defense-in-depth.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The inference broker MUST create the Unix-domain socket file at `data/inference.sock` with permission mode `0660` (read/write for owner and group only, no permissions for others).
- **FR-002**: The inference broker MUST change the group ownership of `data/inference.sock` to a dedicated group ID (GID) configured for inference communication.
- **FR-003**: The configuration for the dedicated inference GID MUST be customizable (e.g., via config or environment variables) and default to a sensible system value or fall back safely if none is provided.
- **FR-004**: If the broker fails to set `0660` permissions or change the group ownership of the socket, it MUST fail loudly and refuse to serve.
- **FR-005**: The broker MUST ensure the socket's parent directory (`data/`) has restricted permissions of `0700` (read, write, search for owner only).
- **FR-006**: The sandbox runner MUST launch agent containers using the container GID aligned with the configured dedicated inference GID (e.g. adding it to supplemental groups or setting the primary GID of the process, ensuring uid:gid 1000:<inference-gid> is used).
- **FR-007**: The sandbox runner MUST only mount the specific socket file `data/inference.sock` into the container at `/tmp/inference.sock`, instead of mounting the parent directory or any other part of the host filesystem.
- **FR-008**: The request-level authentication using the `RUN_TOKEN` MUST remain the load-bearing authorization layer for all connected clients, explicitly serving as the authority deciding if a connected client may obtain inference.

### Key Entities *(include if feature involves data)*

- **Inference Socket**: Represents the Unix-domain socket at `data/inference.sock` used for communication between the host substrate broker and the sandboxed agents. Attributes: path, permissions (mode), group owner (GID).
- **Sandbox Container**: Represents the execution environment of the agent. Attributes: running UID (1000), GID, supplementary GIDs, bind mounts (limited to `/tmp/inference.sock`).
- **Run Token**: A per-run cryptographically random/unique token passed in the request body to authenticate the client requesting inference.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An unauthorized local host process (neither the broker owner nor in the inference GID) attempting to connect to `data/inference.sock` receives a `Permission Denied` error at the OS socket layer (100% rejection rate before token evaluation).
- **SC-002**: A legitimate agent running in the sandboxed container (with GID aligned to the inference GID) successfully connects to the mounted `/tmp/inference.sock` and completes an inference query with a valid `RUN_TOKEN` in under 5 seconds.
- **SC-003**: If GID assignment or permission modification fails during broker initialization, the broker crashes or terminates within 1 second.
- **SC-004**: The parent directory `data/` restricts listing and access to the owner only (0700).
- **SC-005**: The container has no visible host paths mounted other than `/tmp/inference.sock`.

## Assumptions

- The dedicated inference GID is configured in the Elixir application environment (e.g., via config files or system environment variables).
- The host system has the corresponding GID created or available, or it can be set to any arbitrary numeric GID.
- Docker Desktop on macOS maps the file permissions softly, making the `RUN_TOKEN` the load-bearing control for container-to-host boundary authentication.
- Live-container tests requiring full DAC enforcement are tagged as `:docker-gated` and run on a Linux-based CI platform where bind-mount DAC is strictly enforced.
