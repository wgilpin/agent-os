# Data Model & Configuration Entities: Socket Security & Permissions

## Inference Socket Entity

Represents the Unix-domain socket created by the substrate broker for inference communication.

* **Attributes**:
  * `path`: String. Defaults to `"data/inference.sock"`.
  * `mode`: Octal Integer. Must be set to `0o660` (read/write for owner and group only).
  * `gid`: Integer. The group owner ID assigned to the socket file.
* **Validation Rules**:
  * Permission mode must be exactly `0o660`.
  * Group owner must match the configured dedicated inference GID.
  * If ownership or mode cannot be set, the entity is considered invalid, triggering a supervisor crash.

---

## Socket Parent Directory Entity

Represents the directory housing the Unix-domain socket.

* **Attributes**:
  * `path`: String. Defaults to `"data"`.
  * `mode`: Octal Integer. Must be set to `0o700` (read/write/search for owner only).
* **Validation Rules**:
  * Permissions must restrict all operations for groups and other users on the host system to prevent path traversal or file listing bypasses.

---

## Sandbox User Config Entity

Represents the credential configuration passed to the Docker container at runtime.

* **Attributes**:
  * `uid`: Integer. User ID inside the container, defaults to `1000` (non-root).
  * `gid`: Integer. Primary group ID inside the container, aligned dynamically to the configured dedicated inference GID.
* **Validation Rules**:
  * UID must not be `0` (root).
  * GID must equal the configured dedicated inference GID to authorize socket connection.
  * Formatted for Docker client execution as `uid:gid` (e.g. `"1000:1002"`).

---

## Sandbox Mount Entity

Represents a bind-mount mapping host paths into the container.

* **Attributes**:
  * `host_path`: String. Absolute path to the host file/directory.
  * `container_path`: String. Absolute path mapped inside the container.
  * `writable`: Boolean.
* **Validation Rules**:
  * Only the inference socket file mount is allowed to be writable (`writable = true`, container path `/tmp/inference.sock`).
  * Any other mounts must be read-only (`writable = false`, ending with `:ro`).
