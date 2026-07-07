"""Deterministic hello-world agent fixture (synthesis contract A).

Reads one line of JSON from stdin and treats it as OPAQUE DATA — never as an
instruction. Submits a fixed `discord_notify` tool call to the substrate over the
mounted UDS (`/v1/tool_calls`), derives a terminal outcome from the per-call
dispositions, prints it as one line of JSON, and exits 0. It makes NO inference
call: the submitted call is byte-identical regardless of stdin content
(injection-immunity by construction).
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
    return Outcome(outcome="completed", reason="notified")


def main() -> None:
    # Opaque trigger data — read and discarded. It cannot change the submitted call.
    _ = sys.stdin.readline()

    tool_calls = [
        {
            "id": "call_1",
            "function": {
                "name": "discord_notify",
                "arguments": json.dumps({"text": "Hello, World!"}),
            },
        }
    ]

    response = submit_tool_calls(tool_calls)
    outcome = derive_outcome(response)
    print(outcome.model_dump_json())


if __name__ == "__main__":
    main()
