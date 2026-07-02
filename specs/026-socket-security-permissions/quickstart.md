# Quickstart Guide: Socket Security & Permissions

This guide explains how to configure, run, and verify the socket permissions and container group alignment changes.

## 1. Configure the Inference GID

The dedicated inference GID can be configured via environment variables or Application config:

### Option A: Environment Variable (Recommended for Dev/Prod)
Export the GID of a group you want to restrict socket access to:
```bash
export INFERENCE_GID=20  # e.g., 'staff' group on macOS, or a custom 'inference' group on Linux
```

### Option B: Application Config
In `config/config.exs`:
```elixir
config :agent_os,
  inference_gid: 1002
```

*Note: If no GID is configured, it dynamically falls back to the current user's primary GID (so local tests continue to work automatically without any manual configuration).*

---

## 2. Start the Substrate Broker

Start the Elixir application. The `InferenceBroker` starts up and automatically applies socket security:

```bash
mix run --no-halt
```

If it fails to apply the permissions or change ownership (e.g., if you specify a GID you are not a member of and the process doesn't run as root), it will fail to start and crash loudly.

---

## 3. Verify Host Permissions

Verify that the socket directory `data/` has `0700` permissions (owner-only) and the socket `data/inference.sock` has `0660` permissions (owner and group only) with the correct group owner:

```bash
# Check directory permissions
ls -ld data/
# Expected: drwx------  [owner]  [group] ... data/

# Check socket file permissions
ls -l data/inference.sock
# Expected: srw-rw----  [owner]  [target_gid_name] ... data/inference.sock
```

---

## 4. Run Automated Tests

To run the unit and integration tests verifying the socket hardening and container GID alignment:

```bash
# Run Inference Broker tests
mix test test/agent_os/inference_broker_test.exs

# Run Sandbox docker argument generation tests
mix test test/agent_os/sandbox_test.exs

# Run full integration tests (requires docker)
mix test --only docker_gated test/agent_os/sandbox_test.exs
```
