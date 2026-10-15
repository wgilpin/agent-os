"""US1 — bounded, visible retries on invalid tool args.

The malformed broker always returns invalid search_notes arguments, so the
validating framework retries up to the budget (default 2) and then fails closed
with a structured outcome — no unbounded loop, every retry a discrete request.
"""

from __future__ import annotations

import io
import json

from agent_os_runtime import run_agent
from agent_os_runtime.tests.golden import build_agent


def test_retry_budget_bounded_and_visible(malformed_broker):
    """Retries are bounded (2) and each is a discrete metered broker request."""
    out = io.StringIO()
    run_agent(
        build_agent,
        payload_stream=io.StringIO(json.dumps({"task": "go"}) + "\n"),
        out=out,
    )
    outcome = json.loads(out.getvalue().strip())

    assert outcome["outcome"] == "failed"

    # retries=2 => 1 initial + 2 retries = 3 discrete requests, then fail closed.
    # Assert it is bounded and small (never unbounded), matching the bake-off.
    n = malformed_broker.request_count()
    assert n == 3, f"expected exactly 3 bounded requests (1 + 2 retries), got {n}"
