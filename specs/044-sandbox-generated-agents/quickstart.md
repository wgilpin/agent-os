# Quickstart — Sandbox Generated Agents

Prerequisites: Docker running; the config image already builds
(`agent-discovery:dev` present).

## 1. Build the generated-agent runtime image (FR-002)

```bash
# Generic image: venv deps baked, NO agent code baked, no agent-specific entrypoint.
docker build -t agent-generated:dev -f agents/generated.Dockerfile .
```

Verify deps are present and no agent code is baked:

```bash
docker run --rm --entrypoint /app/.venv/bin/python agent-generated:dev \
  -c "import pydantic, google.genai; print('deps ok')"
docker run --rm --entrypoint /bin/sh agent-generated:dev \
  -c "test ! -e /app/agents/discovery && echo 'no baked agent code'"
```

## 2. Run a generated agent jailed (US1 / SC-003)

With the substrate booted (inference broker up, a generated agent deployed), fire a
production run with **no** `agent_cmd` override — it must route to the container:

```elixir
AgentOS.RunWorker.run_once(agent: "<generated-agent-name>", trigger: :timer)
```

Confirm from the run-log + `docker` metadata that it executed via the container runtime
(image `agent-generated:dev`, network none, read-only root, non-root user), reached the
broker over the UDS, and produced its normal outcome record.

Sanity-check import resolution for a bare-import body
(`get_the_local_time…discord_channel` uses `from models import …`): the mounted
`/app/agents/<name>` on `sys.path[0]` resolves it.

## 3. Run the containment probe (US2 / FR-008 / SC-002)

```bash
# Excluded by default; opt in explicitly.
mix test test/agent_os/generated_containment_test.exs --include docker
```

Asserts, for a hostile generated body run under `agent-generated:dev` with a read-only code
mount:

- host-file read outside its mounts → denied;
- outbound socket → refused (`--network none`);
- write outside `/scratch` → denied (`--read-only`);
- each failure surfaces in the run-log/logs (not swallowed).

## 4. Prove no bypass remains (US3 / FR-005)

- Grep confirms the direct-python branch is gone from `lib/agent_os/run_worker.ex` (no
  `agent_cmd: python_bin()` injection for non-config agents).
- An explicit override still works (FR-006):

```elixir
AgentOS.RunWorker.run_once(agent: "x", agent_cmd: "echo", agent_args: [~s({"status":"ok"})])
```

## 5. Induce each loud failure (SC-005)

- Wrong image name → `failure_cause=image_unavailable`.
- Stop Docker → `failure_cause=runtime_unavailable`.
- Remove `agents/<name>/` → `failure_cause=code_unmountable`.

None falls back to an unconfined host run.

## 6. Regression (FR-010 / SC-004)

```bash
mix test                         # default suite (docker excluded) stays green
mix test --include docker        # world-B + isolation + containment, Docker present
```
