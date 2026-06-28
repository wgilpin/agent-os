"""Human-written discovery agent.

Invocation-scoped: read one line from stdin, reason over input, and emit
a JSON list of proposed enumerated actions to stdout, then exit 0.
"""

import json
import sys
from pydantic import BaseModel


class Action(BaseModel):
    type: str
    payload: dict


def build_actions(input_data: dict) -> list[Action]:
    # v0: deterministic stand-in for the pydantic-ai LLM call;
    # swap in Agent.run once an LLM key is wired.
    roster = input_data.get("roster", [])
    actions = []

    if not roster:
        actions.append(
            Action(type="append_digest", payload={"text": "no input"})
        )
        return actions

    for item in roster:
        is_high = False
        text = ""

        if isinstance(item, dict):
            # Check high_signal flag or signal field
            is_high = item.get("high_signal", True) or item.get("signal") == "high"
            text = item.get("text") or item.get("content") or json.dumps(item)
        elif isinstance(item, str):
            is_high = True
            text = item

        if is_high:
            actions.append(
                Action(type="append_digest", payload={"text": f"high-signal: {text}"})
            )

    if not actions:
        actions.append(
            Action(type="append_digest", payload={"text": "no high-signal input"})
        )

    return actions


def main() -> int:
    # Read exactly one line from stdin (matches PortRunner's newlined json)
    raw = sys.stdin.readline().strip()
    try:
        input_data = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        input_data = {}

    actions = build_actions(input_data)

    output = {"actions": [action.model_dump() for action in actions]}
    print(json.dumps(output))
    sys.stdout.flush()

    return 0


if __name__ == "__main__":
    sys.exit(main())
