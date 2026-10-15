# Quickstart — Agent Runtime Kit test tiers

Three test tiers verify the feature. All are offline (Constitution IV).

## Prereqs

- `uv sync` (installs `pydantic-ai-slim[openai]==2.5.0` into `.venv`).
- Elixir deps: `mix deps.get`.
- OrbStack running (for Tier c only).

## Tier (a) — Python kit suite (deterministic, no network)

Seeded from `.planning/bakeoff-agent-framework/harness/` (stub UDS broker + AF_UNIX-only socket jail). This is the **mandatory regression gate for any future framework pin bump** (FR-012, SC-005).

```bash
uv run pytest agent_os_runtime/tests -v
```

Covers: golden 2-tool task over the UDS; env-contract resolution + fail-fast; bounded retries (default 2) → structured failure; history in → context threaded; delta out; malformed history fails fast. Keep fixture socket paths short (AF_UNIX ~104-char limit).

## Tier (b) — Elixir E2E across the port boundary

Runs the sample body (`agents/sample_kit_agent/main.py`) via `.venv/bin/python` against a real broker started with `start_broker_uds!/1` and a scripted `provider_fn` stub (search_notes → add_todo → final).

```bash
mix test test/agent_os/runtime_kit_e2e_test.exs test/agent_os/inference_broker_openai_test.exs
```

Verifies: golden multi-step task completes; single outcome-record line on stdout (outcome/reason [+ history]); call-for-call spend reconciliation; per-call cap + kill-on-breach on the new surface; native path unchanged.

## Tier (c) — In-image `--network=none` containment probe

Extends the spec-044 probe. Build the generated image (kit + framework baked), then run the sample body with only the UDS mounted and no network.

```bash
docker build -f agents/generated.Dockerfile -t agent-generated:dev .
# probe: --network=none, UDS mounted read/write, assert golden success + zero egress + no lazy tiktoken fetch
```

Asserts: golden-task success with zero egress attempts and no lazy asset downloads (tiktoken never fetches). Socket paths kept short.

## Full suite (must stay green — SC-006/SC-007)

```bash
mix test          # world-B suite unchanged; existing native-path agents unchanged
mix format --check-formatted && mix credo
uv run ruff check . && uv run mypy agent_os_runtime
```
