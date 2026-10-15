# agent_os_runtime

First-party Python runtime kit for generated agent bodies (feature 046). Baked into
the generated-agent image; **never generated**. Gives a body two functions so it
carries zero transport/HTTP/socket/env code:

- `substrate_model()` — a `pydantic-ai` `OpenAIChatModel` wired to the inference
  broker over the mounted UDS, resolving `INFERENCE_SOCKET` / `RUN_TOKEN` /
  `AGENT_MODEL` from the sandbox-injected environment contract. The run token is
  presented as the provider `api_key`, i.e. `Authorization: Bearer <run_token>`.
- `run_agent(build_agent)` — the session-shaped invocation wrapper: one JSON payload
  line in (task + optional `history`), one outcome-record line out (`outcome`,
  `reason`, and the run's new-message `history` delta). Owns model construction so a
  broken environment contract becomes a structured failure outcome, not a traceback.

The kit is **DX and early failure only — never enforcement**. The deterministic gate
and the broker remain the sole firewall; the sandbox (`network=none`, UDS-only)
physically constrains a body that ignores the kit.

Golden reference body: `agents/sample_kit_agent/main.py` (< 30 lines, zero transport
code). Tools there are plain in-body functions; connector-registry tool stubs are 13-02.

## Pinned framework

`pydantic-ai-slim[openai]==2.5.0` — exact pin (see `.planning/bakeoff-agent-framework/`
for the decision). Installed into the generated-agent image at build time via
`uv sync --frozen` (never at agent-provision time). The kit is baked on
`PYTHONPATH=/app`.

## Regression gate for a framework pin bump (MANDATORY)

The deterministic Python suite (stub UDS broker + AF_UNIX-only socket jail, seeded
from the bake-off harness) is the **required gate before any framework version
changes** in `pyproject.toml` / the image. It covers transport, bounded retries, and
history threading with **no network**.

```bash
uv run pytest agent_os_runtime/tests -v      # Tier (a): must pass green
```

A proposed bump must additionally re-pass:

```bash
mix test --include docker test/agent_os/kit_offline_probe_test.exs   # Tier (c): --network=none golden task
```

Do not change the pin unless both are green. See
`specs/046-agent-runtime-kit/quickstart.md` for all three test tiers.
