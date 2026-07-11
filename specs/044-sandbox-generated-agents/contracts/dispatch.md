# Contract — Shared Sandbox Dispatch

The single route (`AgentOS.RunWorker`) that turns *an agent + its mounts* into a contained
container invocation, used by **both** config and generated agents (FR-004). This is the
internal substrate contract exercised by the world-B and containment suites.

## Inputs

- `opts[:agent]` or `opts[:manifest_path]` → resolves `agent_name` (else the config agent).
- `opts[:agent_cmd]` → optional explicit command override (tests/harnesses).
- Runtime config: `:agent_image`, `:generated_agent_image`, `:inference_uds_path`,
  `:agent_runtime_model`; inference GID from `InferenceBroker.get_configured_gid/0`.

## Decision procedure

```
1. explicit_cmd? = has_key(opts, :agent_cmd) and opts[:agent_cmd] != "docker"
   → if true: dispatch {opts[:agent_cmd], opts[:agent_args]} unchanged.  [FR-006]
              (no sandbox, no pre-flight — harness/test path)

2. otherwise (production path):  [FR-005 — no host-python branch exists]
   config_agent? = agent_name == config_agent_name
   image        = config_agent? ? :agent_image : :generated_agent_image
   entrypoint   = config_agent? ? nil : "/app/.venv/bin/python"
   cmd_args     = config_agent? ? nil : ["/app/agents/<name>/main.py"]
   mounts       = [ {expand(:inference_uds_path), "/tmp/inference.sock"} ]
                  ++ (config_agent? ? [] : [ {expand("agents/<name>"), "/app/agents/<name>:ro"} ])

3. PRE-FLIGHT (production path only), loud on failure, no fallback:  [FR-009]
   a. if not config_agent? and not File.dir?(expand("agents/<name>")) → fail code_unmountable
   b. run `docker image inspect <image>`:
        exit 0                                  → proceed
        stderr ~ "Cannot connect to the Docker daemon" → fail runtime_unavailable
        else                                    → fail image_unavailable

4. build argv = Sandbox.build_argv(%Sandbox{image, entrypoint, cmd_args, mounts,
                network:"none", user: <uid>:<inference_gid>, limits...})
   dispatch {"docker", argv} via PortRunner.
```

## Guarantees (map to FR / acceptance)

| Guarantee | Requirement |
|-----------|-------------|
| Production generated dispatch is always the container runtime, never a host interpreter | FR-001, FR-005, US1-AC1, US3-AC1 |
| Config & generated share `Sandbox.build_argv/1`; differ only in image + mounts + entrypoint | FR-004, US1-AC3 |
| Generated code mounted read-only; inference UDS is the sole writable host mount | FR-003, FR-007, US1-AC2 |
| `RUN_TOKEN`, `INFERENCE_SOCKET`, `AGENT_MODEL` injected into the container as for the config agent | FR-007, US1-AC2 |
| Explicit `:agent_cmd` override honoured unchanged | FR-006, US3-AC2 |
| Missing image / daemon down / unmountable code fail loudly with distinct cause, no fallback | FR-009, edge cases, SC-005 |
| Payload shape branches on `config_agent?`, not on `cmd == "docker"` | (correctness; boundary invariant) |

## Non-goals (unchanged by this contract)

- Gate / capability-rail authority mediation (below-the-gate containment only).
- Inference-channel protocol (reused as-is).
- Runtime selection knob (`runc`/`runsc`) and VM backend — Phase 11-03 / 11-04.
