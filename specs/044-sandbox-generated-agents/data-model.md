# Phase 1 Data Model — Sandbox Generated Agents

This feature adds no persistent store. The "entities" are the dispatch-decision inputs and
the run-log failure vocabulary. Types are the existing `%AgentOS.Sandbox{}` struct plus the
`run_worker` dispatch locals.

## Dispatch decision inputs (`RunWorker.run_once/1` / `execute_run/6`)

| Field | Type | Source | Meaning |
|-------|------|--------|---------|
| `agent_name` | `binary()` | `Path.basename(manifest_path, ".md")` | The dispatched agent |
| `config_agent` | `binary()` | `Path.basename(cfg.manifest_path, ".md")` | The substrate config/discovery agent name |
| `config_agent?` | `boolean()` | `agent_name == config_agent` | **New discriminator** — replaces `cmd == "docker"` for payload/bookmark branching |
| `explicit_cmd?` | `boolean()` | `Keyword.has_key?(opts, :agent_cmd) and get(:agent_cmd) != "docker"` | FR-006 override present ⇒ dispatch as directed, skip sandbox build |
| `image` | `binary()` | config key (see below) | `agent_image` when `config_agent?`, else `generated_agent_image` |
| `entrypoint` | `binary() \| nil` | dispatch | `nil` for config (baked ENTRYPOINT), `"/app/.venv/bin/python"` for generated |
| `cmd_args` | `[binary()] \| nil` | dispatch | `nil` for config, `["/app/agents/<name>/main.py"]` for generated |
| `code_mount` | `{binary(), binary()} \| nil` | dispatch | `nil` for config, `{Path.expand("agents/<name>"), "/app/agents/<name>:ro"}` for generated |

## `%AgentOS.Sandbox{}` (existing — reused verbatim)

No struct change. Generated dispatch populates the existing fields:

- `image` — generated runtime image.
- `entrypoint` / `cmd_args` — override to run the mounted body.
- `mounts` — `[inference_socket_mount, code_mount]`. `sandbox.ex` already enforces: only
  `/tmp/inference.sock` may be writable and its host path must equal the configured UDS; every
  other mount **must** end `:ro`. The code mount (`…:ro`) satisfies this (FR-003).
- `network` (`"none"`), `user` (non-root, GID-aligned to the inference group), memory/pids/
  nofile limits, `--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges` — all
  unchanged; this **is** the shared containment posture (FR-001, FR-004).

## Configuration keys (`config/config.exs`)

| Key | Default | Meaning |
|-----|---------|---------|
| `:agent_image` | `"agent-discovery:dev"` | Config-agent runtime image (was hard-coded in `run_worker`) |
| `:generated_agent_image` | `"agent-generated:dev"` | Generic generated-agent runtime image (FR-002) |

## Run-log failure vocabulary (FR-009 / SC-005)

Distinct, diagnosable `failure_cause` values written to the run-log; each also logs `:error`.
None resolves to an unconfined fallback.

| `failure_cause` | Trigger | Returned reason |
|-----------------|---------|-----------------|
| `code_unmountable` | `agents/<name>/` absent/unreadable pre-flight | `{:error, :code_unmountable}` |
| `image_unavailable` | `docker image inspect` fails, image missing | `{:error, :image_unavailable}` |
| `runtime_unavailable` | `docker image inspect` fails, daemon down | `{:error, :runtime_unavailable}` |
| `crash` | container non-zero exit (incl. denied host op) | `{:error, {:exit_status, code}}` |
| `oom` | container exit 137 | `{:error, {:exit_status, 137}}` |
| `timeout` | no output within `timeout_ms` | `{:error, :timeout}` |

(`crash`/`oom`/`timeout` are pre-existing; the three new pre-flight causes are added.)
