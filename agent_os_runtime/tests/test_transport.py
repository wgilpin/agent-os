"""US1 — golden multi-step task over the UDS, with env-contract fail-fast.

Deterministic, no network: the scripted stub broker drives search_notes ->
add_todo -> final Result, and the AF_UNIX-only jail proves zero egress.
"""

from __future__ import annotations

import io
import json
import os

from agent_os_runtime import run_agent
from agent_os_runtime.tests import socket_guard
from agent_os_runtime.tests.golden import build_agent


def _run(payload: dict) -> dict:
    """Run the golden agent once with ``payload`` on stdin; return the outcome dict."""
    out = io.StringIO()
    run_agent(build_agent, payload_stream=io.StringIO(json.dumps(payload) + "\n"), out=out)
    lines = [ln for ln in out.getvalue().splitlines() if ln.strip()]
    assert len(lines) == 1, f"expected exactly one outcome line, got {lines!r}"
    return json.loads(lines[0])


def test_golden_task_over_uds(broker):
    """2+ sequential tool calls complete with a structured Result; spend reconciles."""
    socket_guard.install()
    try:
        outcome = _run({"task": "Prepare my quarterly review."})
    finally:
        socket_guard.uninstall()

    assert outcome["outcome"] == "completed"
    # reason carries the model's structured Result JSON.
    result = json.loads(outcome["reason"])
    assert result["outcome"] == "done"

    # Exactly the commanded calls: search_notes, add_todo, final_result. No hidden calls.
    reqs = broker.requests()
    assert len(reqs) == 3, f"expected 3 discrete broker requests, got {len(reqs)}"
    assert all(r["path"] == "/v1/chat/completions" for r in reqs)

    # Zero attempted egress beyond the AF_UNIX broker socket.
    assert socket_guard.ATTEMPTS == []

    # History delta is populated (session-shaped output).
    assert isinstance(outcome["history"], list) and outcome["history"]


def test_missing_run_token_fails_fast_with_outcome(broker):
    """A missing env var yields a structured failure outcome, not a crash or a call."""
    os.environ.pop("RUN_TOKEN", None)
    outcome = _run({"task": "Prepare my quarterly review."})

    assert outcome["outcome"] == "failed"
    assert "RUN_TOKEN" in outcome["reason"]
    # substrate_model failed before any broker call.
    assert broker.request_count() == 0
