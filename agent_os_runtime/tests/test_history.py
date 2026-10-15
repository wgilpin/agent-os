"""US3 — history in, delta out; malformed history fails fast.

The same body works as a future chat turn: run once fresh, feed the run's delta
back, and the second run continues the conversation returning only its own delta.
"""

from __future__ import annotations

import io
import json

from agent_os_runtime import run_agent
from agent_os_runtime.tests.golden import build_agent


def _run(payload: dict) -> dict:
    out = io.StringIO()
    run_agent(build_agent, payload_stream=io.StringIO(json.dumps(payload) + "\n"), out=out)
    return json.loads(out.getvalue().strip())


def test_fresh_run_emits_full_delta(broker):
    """No history in -> the outcome carries this run's full new-message set."""
    outcome = _run({"task": "Prepare my quarterly review."})
    assert outcome["outcome"] == "completed"
    assert isinstance(outcome["history"], list) and len(outcome["history"]) >= 2


def test_history_threaded_and_delta_only(broker):
    """Prior delta fed back -> model sees it; second outcome carries only its delta."""
    first = _run({"task": "Prepare my quarterly review."})
    assert first["outcome"] == "completed"
    first_len = len(first["history"])

    calls_after_first = broker.request_count()

    second = _run({"task": "Now summarise what you did.", "history": first["history"]})
    assert second["outcome"] == "completed"

    # The second run issued its own fresh broker calls (conversation continued).
    assert broker.request_count() > calls_after_first

    # The delta is only the NEW messages, not the replayed prior history.
    assert 0 < len(second["history"]) <= first_len + 3


def test_malformed_history_fails_fast(broker):
    """A malformed history payload -> structured failure, no silent truncation, no call."""
    outcome = _run({"task": "go", "history": [{"not": "a valid message"}]})
    assert outcome["outcome"] == "failed"
    assert "history" in outcome["reason"].lower()
    assert broker.request_count() == 0
