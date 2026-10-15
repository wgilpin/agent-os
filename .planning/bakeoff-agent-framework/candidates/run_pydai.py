"""pydantic-ai golden-task runner over the UDS broker (network jailed).

Transport: OpenAIChatModel + OpenAIProvider with a custom httpx.AsyncClient whose
transport is httpx.AsyncHTTPTransport(uds=<broker.sock>). This is the first-class,
documented way to point an OpenAI-compatible provider at a Unix domain socket.

Run:  run_pydai.py <sock> <log> <mode>
Prints a JSON metrics line to stdout as PYDAI_RESULT=<json>.
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "harness"))
import socket_guard  # noqa: E402
import runner_common  # noqa: E402

SOCK = sys.argv[1]
LOG = sys.argv[2]
MODE = sys.argv[3] if len(sys.argv) > 3 else "normal"


def main():
    # --- network jail on BEFORE any framework I/O ---
    socket_guard.install()

    import httpx
    from pydantic import BaseModel
    from pydantic_ai import Agent
    from pydantic_ai.models.openai import OpenAIChatModel
    from pydantic_ai.providers.openai import OpenAIProvider

    class Result(BaseModel):
        outcome: str
        reason: str

    tool_hits = []

    # --- the UDS transport: this snippet is the seed of agent_os_runtime ---
    uds_client = httpx.AsyncClient(
        transport=httpx.AsyncHTTPTransport(uds=SOCK),
        base_url="http://localhost/v1",
        timeout=30.0,
    )
    provider = OpenAIProvider(
        base_url="http://localhost/v1", api_key="stub-key", http_client=uds_client
    )
    model = OpenAIChatModel("stub-model", provider=provider)

    agent = Agent(
        model,
        output_type=Result,
        system_prompt=(
            "Search the user's notes, then add a todo. "
            "Finish by reporting the outcome."
        ),
        retries=2,
    )

    @agent.tool_plain
    def search_notes(query: str) -> str:
        """Search the user's notes for a query string."""
        tool_hits.append(("search_notes", query))
        return "found 3 notes matching the query"

    @agent.tool_plain
    def add_todo(title: str, link: str) -> str:
        """Add a todo item with a title and a link."""
        tool_hits.append(("add_todo", title, link))
        return "todo added"

    result = {"candidate": "pydantic-ai-slim==2.5.0", "mode": MODE}
    try:
        run = agent.run_sync("Prepare my quarterly review.")
        out = run.output
        result["status"] = "PASS"
        result["output"] = out.model_dump() if hasattr(out, "model_dump") else str(out)
        result["output_type_ok"] = isinstance(out, Result)
        result["tool_hits"] = tool_hits
    except Exception as e:
        result["status"] = "FAIL"
        result["error"] = f"{type(e).__name__}: {e}"
        result["tool_hits"] = tool_hits
    result["egress_attempts"] = socket_guard.ATTEMPTS
    print("PYDAI_RESULT=" + json.dumps(result))


if __name__ == "__main__":
    main()
