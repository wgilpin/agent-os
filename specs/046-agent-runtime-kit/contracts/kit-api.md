# Contract — `agent_os_runtime` public API

First-party Python kit at the repo root. Two public functions. Generated bodies import ONLY the kit for transport/invocation and pydantic-ai for agent declaration.

## `substrate_model() -> OpenAIChatModel`

```python
from agent_os_runtime import substrate_model
```

- Reads `INFERENCE_SOCKET`, `RUN_TOKEN`, `AGENT_MODEL` from the environment (the sandbox-injected contract). The body never reads these itself (FR-002).
- Builds `httpx.AsyncClient(transport=httpx.AsyncHTTPTransport(uds=INFERENCE_SOCKET), base_url="http://localhost/v1", timeout=…)`.
- Builds `OpenAIProvider(base_url="http://localhost/v1", api_key=RUN_TOKEN, http_client=<uds client>)` — `api_key=RUN_TOKEN` makes the provider send `Authorization: Bearer <RUN_TOKEN>` (the broker's auth, no kit-side rewriting; FR-003).
- Returns `OpenAIChatModel(AGENT_MODEL, provider=…)`.
- **Fails fast** (raises a typed kit error, surfaced by `run_agent` as a structured failure outcome) when any var is missing/empty or `INFERENCE_SOCKET` exceeds the AF_UNIX path limit. (FR-009)

## `run_agent(agent, *, payload_stream=sys.stdin, out=sys.stdout) -> None`

```python
from agent_os_runtime import run_agent
```

Wraps the PortRunner stdin/stdout contract (FR-005): one JSON payload line in, one outcome-record line out.

1. Read exactly one line from stdin; parse into `InvocationPayload`. Empty/malformed input → structured failure outcome.
2. If `payload.history` present → deserialize via pydantic-ai's `ModelMessagesTypeAdapter`; malformed → fail fast, structured failure outcome (FR-009, no silent truncation).
3. `result = agent.run_sync(<task from payload>, message_history=<history or None>)`.
4. On success → emit `OutcomeRecord(outcome="completed", reason=<summary>, history=<result.new_messages() serialized>)` as one JSON line.
5. On ANY exception (env, transport/broker-unreachable with bounded retries exhausted, tool/validation retry exhaustion, output-validation failure) → emit `OutcomeRecord(outcome="failed", reason=<diagnosable cause>, history=<partial delta or []>)`. Never hang, never unbounded-retry, never exit without a record (FR-009).

The `agent` is a `pydantic_ai.Agent` the body constructed with `model=substrate_model()`, its `output_type`, `system_prompt`, `@agent.tool_plain` functions, and `retries=2` (the kit default; the sample body passes it explicitly for legibility).

## Sample golden body (`agents/sample_kit_agent/main.py`) — the acceptance shape

Must be **< 30 lines** with **zero** socket/HTTP/header/env-var handling (FR-010, SC-001/SC-002):

```python
from pydantic import BaseModel
from pydantic_ai import Agent
from agent_os_runtime import substrate_model, run_agent

class Result(BaseModel):
    outcome: str
    reason: str

agent = Agent(
    substrate_model(),
    output_type=Result,
    system_prompt="Search the user's notes, then add a todo, then report the outcome.",
    retries=2,
)

@agent.tool_plain
def search_notes(query: str) -> str:
    """Search the user's notes for a query string."""
    return "found 3 notes matching the query"

@agent.tool_plain
def add_todo(title: str, link: str) -> str:
    """Add a todo item with a title and a link."""
    return "todo added"

if __name__ == "__main__":
    run_agent(agent)
```

Golden task = `search_notes` → `add_todo` → final `Result` (2+ sequential tool calls; bake-off shape). Tools are plain in-body functions — connector-registry stubs are 13-02.

## Quality gates

- `ruff` clean, `mypy` clean, docstrings on every function (Constitution V/VII).
- No framework feature enabled that issues uncommanded calls (telemetry/background/implicit-tool/direct-provider fallback) (FR-007).
