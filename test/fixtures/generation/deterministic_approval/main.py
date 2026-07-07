"""Deterministic fixture targeting an approval-required connector.

Identical contract to the hello-world fixture, but hard-codes an `external_send`
call — an approval-required capability — so the E2E can verify the body derives an
`{"outcome": "parked"}` record from a parked disposition.
"""

import os
import sys
import json
import socket

from models import Outcome


def submit_tool_calls(tool_calls: list[dict]) -> dict:
    """Submits hard-coded tool calls to the substrate gate over the mounted UDS."""
    run_token = os.environ["RUN_TOKEN"]
    socket_path = os.environ["INFERENCE_SOCKET"]

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(socket_path)

    body = json.dumps({"run_token": run_token, "tool_calls": tool_calls})
    request = (
        "POST /v1/tool_calls HTTP/1.1\r\n"
        "Host: localhost\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    ) + body
    s.sendall(request.encode("utf-8"))

    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    s.close()

    _, response_body = data.decode("utf-8").split("\r\n\r\n", 1)
    return json.loads(response_body)


def derive_outcome(response: dict) -> Outcome:
    """Terminal outcome from the per-call dispositions (transcript is the truth)."""
    dispositions = [r.get("disposition") for r in response.get("results", [])]
    if any(d == "parked" for d in dispositions):
        return Outcome(outcome="parked", reason="pending approval")
    if any(d == "rejected" for d in dispositions):
        return Outcome(outcome="rejected", reason="gated by substrate")
    return Outcome(outcome="completed", reason="sent")


def main() -> None:
    _ = sys.stdin.readline()

    tool_calls = [
        {
            "id": "call_1",
            "function": {
                "name": "external_send",
                "arguments": json.dumps({"text": "hi", "recipient": "owner-inbox"}),
            },
        }
    ]

    response = submit_tool_calls(tool_calls)
    outcome = derive_outcome(response)
    print(outcome.model_dump_json())


if __name__ == "__main__":
    main()
