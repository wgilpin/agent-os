import sys
import os
import socket
import json
from models import Outcome

def submit_tool_calls(tool_calls: list[dict]) -> dict:
    """Submits hard-coded tool calls to the substrate gate over the mounted UDS."""
    run_token = os.environ.get("RUN_TOKEN")
    socket_path = os.environ.get("INFERENCE_SOCKET")

    if not run_token or not socket_path:
        raise RuntimeError("Substrate environment variables not set")

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(socket_path)

    payload = {"run_token": run_token, "tool_calls": tool_calls}
    body = json.dumps(payload)
    request = (
        f"POST /v1/tool_calls HTTP/1.1\r\n"
        f"Host: localhost\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: close\r\n\r\n"
        f"{body}"
    )
    s.sendall(request.encode("utf-8"))

    response_data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        response_data += chunk
    s.close()

    response_str = response_data.decode("utf-8")
    headers_str, response_body = response_str.split("\r\n\r\n", 1)
    status_code = int(headers_str.split("\r\n")[0].split(" ")[1])
    response_json = json.loads(response_body)
    if status_code != 200:
        raise RuntimeError(f"Tool channel error: status {status_code}")
    return response_json

def main():
    # Read one line of opaque data from stdin to satisfy the trigger mechanism
    try:
        sys.stdin.readline()
    except Exception:
        pass

    # Hardcode the discord_notify tool call to send Hello World
    tool_calls = [
        {
            "id": "call_discord_notify",
            "function": {
                "name": "discord_notify",
                "arguments": json.dumps({"text": "Hello, World!"})
            }
        }
    ]

    response = submit_tool_calls(tool_calls)
    results = response.get("results", [])

    # Classify the outcome according to priority order
    outcome_state = "completed"
    reason = "Notification sent successfully."

    # Check if there is an error
    for res in results:
        disposition = res.get("disposition")
        content = res.get("content")
        if disposition == "error":
            outcome_state = "error"
            reason = json.dumps(content) if isinstance(content, (dict, list)) else str(content)
            break

    # Check if there is a rejection (if not already error)
    if outcome_state != "error":
        for res in results:
            disposition = res.get("disposition")
            content = res.get("content")
            if disposition == "rejected":
                outcome_state = "rejected"
                reason = json.dumps(content) if isinstance(content, (dict, list)) else str(content)
                break

    # Check if there is a parked status (if not error or rejected)
    if outcome_state not in ("error", "rejected"):
        for res in results:
            disposition = res.get("disposition")
            if disposition == "parked":
                outcome_state = "parked"
                reason = "pending approval"
                break

    outcome_val = Outcome(outcome=outcome_state, reason=reason)
    print(outcome_val.model_dump_json())
    sys.exit(0)

if __name__ == "__main__":
    main()