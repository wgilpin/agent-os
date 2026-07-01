# Data Model: Sandbox Execution Structure

This document defines the properties and validation constraints for the container sandbox configuration.

## Struct: `AgentOS.Sandbox`

The `AgentOS.Sandbox` struct encapsulates all options required to construct the execution arguments for the Docker container.

### Fields

| Field Name | Type | Description | Default / Ceiling |
|------------|------|-------------|-------------------|
| `image` | `binary()` | The container image to run. | None (Required) |
| `cidfile` | `binary()` | Path to the container ID tracking file. | None (Required) |
| `network` | `binary() \| nil` | The network configuration mode. | Must be `"none"` |
| `memory_mb` | `pos_integer() \| nil` | Memory allocation in megabytes. | Default: `128`, Ceiling: `128` |
| `cpus` | `binary() \| float() \| nil` | CPU resource allocation limit. | Default: `"0.5"`, Ceiling: `0.5` |
| `user` | `binary() \| nil` | UID/GID or username under which to run. | Default: `"1000:1000"`, Ceiling: Non-root |
| `env` | `map() \| nil` | Key-value environment variables. | None |
| `entrypoint` | `binary() \| nil` | Optional custom container entrypoint. | None |
| `cmd_args` | `[binary()] \| nil` | Command arguments passed to the entrypoint. | None |
| `mounts` | `[{binary(), binary()}] \| nil` | List of host-to-container volume mappings. | `/tmp/inference.sock` (RW), all others must be `:ro` |

### Validation Rules

1. **User Identity check**:
   - The `user` field is split on `:`. The first segment must not be `"0"` or `"root"`.
   - Action: Throws `ArgumentError`.

2. **Network isolation check**:
   - The `network` field must be `"none"`.
   - Action: Throws `ArgumentError`.

3. **Memory capacity check**:
   - The `memory_mb` field must not exceed `128`.
   - Action: Throws `ArgumentError`.

4. **CPU capacity check**:
   - The `cpus` field (parsed as a float) must not exceed `0.5`.
   - Action: Throws `ArgumentError`.

5. **Storage mount write capability check**:
   - If `mounts` is populated, each mount mapping `{host, container}` is validated.
   - The `container` path must either be exactly `"/tmp/inference.sock"` OR must end with `":ro"`.
   - Action: Throws `ArgumentError`.
