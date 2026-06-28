# Quickstart: Isolate the Discovery Agent

Prerequisites: Docker available and running. (Per project rule, Docker commands are run
with your approval — these are the commands a developer/operator runs by hand.)

## 1. Build the agent image

```bash
docker build -t agent-discovery:dev -f agents/discovery/Dockerfile agents/discovery
```

## 2. (No network setup needed)

The agent container runs with `--network none` this phase — there is no network or proxy to
configure. An egress allowlist arrives only when a real LLM call is wired (later phase).

## 3. Manual on-demand run (FR-010)

```bash
# Triggers one isolated run now, outside the 07:00 timer:
mix run -e 'AgentOS.Scheduler.run_now(:manual)'
# then read what it did — legibly, without asking the agent:
cat data/run_log.md
```

## 4. Run the tests

```bash
# Fast, hermetic suite (no Docker, no network) — sanitizer + sandbox argv builder:
mix test --exclude docker

# Full suite incl. in-container isolation/OOM/crash checks (requires Docker):
mix test

# Python agent contract + sanitization parity (stub model, no live LLM):
uv run pytest agents/discovery
```

## 5. What "done" looks like

- `mix test` green, including the `:docker`-tagged isolation tests.
- A forced crash and a forced OOM both show up in `data/run_log.md` as `:failed` with a
  cause, and the supervisor restarts once then alerts.
- `docker ps` is clean after a timeout/crash (no orphaned containers).
- A hostile bookmark fixture (prompt-injection + malformed payload) produces no
  out-of-grant action and no isolation escape.
