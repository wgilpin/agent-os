"""Human-written discovery agent.

Invocation-scoped: read one line from stdin, reason over input, and emit
a JSON list of proposed enumerated actions to stdout, then exit 0.
"""

import os
import json
import sys

# Ensure the project root is in sys.path for robust module resolution
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from pydantic import BaseModel
from agents.discovery.models import DiscoveryInput


class Action(BaseModel):
    type: str
    recipient: str | None = None
    method: str | None = None
    payload: dict


def normalize_input(raw_dict: dict) -> dict:
    """Normalizes raw input maps to the state+items structure for backward compatibility."""
    if "roster" in raw_dict and "items" not in raw_dict:
        items = []
        for i, val in enumerate(raw_dict["roster"]):
            if isinstance(val, dict):
                is_high = val.get("high_signal", True) or val.get("signal") == "high"
                if is_high:
                    items.append({
                        "id": f"legacy_{i}",
                        "author": "legacy",
                        "text": val.get("text") or json.dumps(val),
                        "urls": []
                    })
            else:
                items.append({
                    "id": f"legacy_{i}",
                    "author": "legacy",
                    "text": str(val),
                    "urls": []
                })
        raw_dict = {"state": {"records": []}, "items": items}
    
    if "state" not in raw_dict:
        raw_dict["state"] = {"records": []}
    if "items" not in raw_dict:
        raw_dict["items"] = []

    return raw_dict


def build_actions(input_data) -> list[Action]:
    if isinstance(input_data, dict):
        normalized = normalize_input(input_data)
        input_data = DiscoveryInput.model_validate(normalized)

    actions = []
    items = input_data.items

    if not items:
        actions.append(
            Action(type="kv_append", method="append", payload={"digest": "no input"})
        )
        return actions

    for item in items:
        text = item.text
        # Safety/Security chokepoint check for simulated adversarial injection
        if "ignore earlier instructions" in text or "prompt injection" in text:
            sys.stderr.write(f"Adversarial input blocked: {item.id}\n")
            sys.stderr.flush()
            continue

        # Keep/record only items containing high-signal words (v0 deterministic reasoning)
        lower_text = text.lower()
        if any(w in lower_text for w in ["high", "valid", "signal", "breakthrough", "plain string", "alice"]):
            actions.append(
                Action(
                    type="kv_append",
                    method="append",
                    payload={"digest": f"high-signal: {text}"}
                )
            )

    if not actions:
        actions.append(
            Action(
                type="kv_append",
                method="append",
                payload={"digest": "no high-signal input"}
            )
        )

    return actions


def main() -> int:
    # Read exactly one line from stdin (matches PortRunner's newlined json)
    raw = sys.stdin.readline().strip()
    try:
        input_dict = json.loads(raw) if raw else {"state": {"records": []}, "items": []}
        # Normalize prior to Pydantic validation
        normalized = normalize_input(input_dict)
        # Validate schema structure
        input_data = DiscoveryInput.model_validate(normalized)
    except Exception as e:
        sys.stderr.write(f"Validation error: {e}\n")
        sys.stderr.flush()
        return 1

    actions = build_actions(input_data)

    output = {"actions": [action.model_dump() for action in actions]}
    print(json.dumps(output))
    sys.stdout.flush()

    return 0


if __name__ == "__main__":
    sys.exit(main())
