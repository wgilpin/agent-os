# Research Notes: Socket Security & Permissions

## Socket Permissions Modification

* **Decision**: Use Erlang's `:file.change_group/2` to modify group ownership and Elixir's `File.chmod/2` to set the socket mode to `0660`.
* **Rationale**: `:file.change_group/2` is built directly into Erlang's `:file` module, avoiding external shell execution overhead. Elixir's `File.chmod/2` is the standard library wrapper for `chmod(2)`.
* **Alternatives considered**: Spawning an external process (e.g. `System.cmd("chgrp", ...)`). Rejected because native BEAM APIs are available, performant, and platform-independent, adhering to Principle I (Simplicity First).

---

## Dynamic GID Selection

* **Decision**: Retrieve the target inference GID from:
  1. The `INFERENCE_GID` environment variable.
  2. The Elixir application configuration `:agent_os, :inference_gid`.
  3. Dynamic fallback to the current system user's GID using `System.cmd("id", ["-g"])` (defaults to `1000` if commands fail).
* **Rationale**: POSIX systems prevent non-root users from changing a file's group ownership to a GID they are not a member of (returns `EPERM`). Falling back to the current user's primary GID ensures developer environments can run tests and broker services locally without crashing due to permissions errors.
* **Alternatives considered**: Hardcoding a default GID (e.g., `1000` or `1002`). Rejected because it would cause constant `eperm` crashes on development machines when running local tests.

---

## Loud Failure & Server Refusal

* **Decision**: If any step in securing the socket (chmod to `0660`, chgrp to target GID, or parent directory chmod to `0700`) fails, return `{:stop, {:uds_listener_failed, reason}}` from `InferenceBroker.init/1`.
* **Rationale**: Ensures the application does not start or continue serving when the socket layer is insecure. This satisfies the loud failure rule (Constitution VI) and ensures a fail-secure state.
* **Alternatives considered**: Logging a warning and proceeding with default permissions. Rejected because it violates the security guarantee.

---

## macOS VM Bind-Mount Limitations

* **Decision**: Explicitly document that group ownership and DAC rules are only softly enforced on macOS Docker Desktop across the hypervisor file sharing boundary. The request-level `RUN_TOKEN` remains the load-bearing authority for container authentication, with GID-aligned socket permissions acting as defense-in-depth.
* **Rationale**: Docker Desktop file sharing layer maps permissions between host and VM. The portable GID alignment model is implemented to work on native Linux (hard enforcement) while maintaining local development compatibility on macOS.
