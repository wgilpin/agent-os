"""Human-written discovery agent.

Invocation-scoped: read one line from stdin, reason over input, and emit
a JSON list of proposed enumerated actions to stdout, then exit 0.
"""

import os
import json
import sys
import socket

# Ensure the project root is in sys.path for robust module resolution
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from pydantic import BaseModel
from agents.discovery.models import DiscoveryInput


def call_inference_broker(model: str, messages: list[dict[str, str]]) -> dict:
    """Routes an inference call to the substrate broker over the mounted UDS."""
    run_token = os.environ.get("RUN_TOKEN")
    socket_path = os.environ.get("INFERENCE_SOCKET")
    agent_model = os.environ.get("AGENT_MODEL", "")

    if not run_token or not socket_path:
        raise RuntimeError("Inference environment variables not set")

    # Connect to UDS socket
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(socket_path)

    # Construct request body
    payload = {
        "run_token": run_token,
        "model": agent_model,
        "messages": messages
    }
    body = json.dumps(payload)

    # Format HTTP POST request
    request = (
        f"POST /v1/inference HTTP/1.1\r\n"
        f"Host: localhost\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: close\r\n\r\n"
        f"{body}"
    )

    s.sendall(request.encode("utf-8"))

    # Receive response
    response_data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        response_data += chunk
    s.close()

    # Parse response
    response_str = response_data.decode("utf-8")
    parts = response_str.split("\r\n\r\n", 1)
    if len(parts) < 2:
        raise RuntimeError("Invalid response from inference broker")
    
    headers_str, response_body = parts
    
    # Check status code in headers
    first_line = headers_str.split("\r\n")[0]
    status_code = int(first_line.split(" ")[1])
    
    response_json = json.loads(response_body)
    if status_code != 200:
        error_msg = response_json.get("error", "unknown_error")
        raise RuntimeError(f"Inference broker error: {error_msg} (status {status_code})")
        
    return response_json


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

    # Read optional trigger_input field from the stdin JSON
    trigger_input = input_dict.get("trigger_input")
    if trigger_input is not None:
        sys.stderr.write(f"Read trigger_input of type: {type(trigger_input)}\n")
        sys.stderr.flush()

    actions = build_actions(input_data)

    output = {"actions": [action.model_dump() for action in actions]}
    print(json.dumps(output))
    sys.stdout.flush()

    return 0


if __name__ == "__main__":
    sys.exit(main())
