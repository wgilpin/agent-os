"""Scripted stub inference broker for the kit's deterministic test suite.

Seeded from ``.planning/bakeoff-agent-framework/harness/broker.py``. A minimal
HTTP/1.1 server on a Unix domain socket that speaks OpenAI chat-completions JSON,
mirroring the real ``AgentOS.InferenceBroker`` UDS listener. It accepts both
``/v1/inference`` and ``/v1/chat/completions``.

It is SCRIPTED by conversation state (not a blind counter) so it is robust to the
framework's message threading:

  * no search_notes result yet          -> tool_call for search_notes(query)
  * search_notes done, no add_todo yet  -> tool_call for add_todo(title, link)
  * both tools done                     -> the FINAL answer, emitted as a tool_call
                                           to the framework's output tool
                                           (e.g. pydantic-ai's ``final_result``).

Every request is logged (count + path + full body) as one JSONL line, which is how
the tests detect hidden/uncommanded calls and count retries. ``malformed`` mode
always returns invalid search_notes args so a validating framework retries.
"""

from __future__ import annotations

import json
import os
import socket
import threading
import time

SEARCH = "search_notes"
ADD_TODO = "add_todo"
KNOWN_TOOLS = {SEARCH, ADD_TODO}


def log_request(log_path: str, n: int, path: str, body: str) -> None:
    """Append one JSONL request record (used for call-for-call reconciliation)."""
    rec = {"n": n, "ts": time.time(), "path": path, "body": body}
    with open(log_path, "a") as f:
        f.write(json.dumps(rec) + "\n")


def tool_call_msg(call_id: str, name: str, args_obj: dict) -> dict:
    """Build an assistant message requesting one function tool call."""
    return {
        "role": "assistant",
        "content": None,
        "tool_calls": [
            {
                "id": call_id,
                "type": "function",
                "function": {"name": name, "arguments": json.dumps(args_obj)},
            }
        ],
    }


def completion(message: dict, finish_reason: str) -> dict:
    """Wrap a message into an OpenAI chat.completion envelope with token usage."""
    return {
        "id": "chatcmpl-stub",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": "stub-model",
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
        "usage": {"prompt_tokens": 20, "completion_tokens": 10, "total_tokens": 30},
    }


def tools_called_in(messages: list) -> set:
    """Return the known tool names that already have a tool result in history."""
    done: set = set()
    id_to_name: dict = {}
    for m in messages:
        if not isinstance(m, dict):
            continue
        for tc in m.get("tool_calls") or []:
            fn = tc.get("function") or {}
            id_to_name[tc.get("id")] = fn.get("name")
        if m.get("role") == "tool":
            name = m.get("name") or id_to_name.get(m.get("tool_call_id"))
            if name in KNOWN_TOOLS:
                done.add(name)
    return done


def find_output_tool(req: dict) -> str | None:
    """Return the framework's registered output/result tool name, if any."""
    for t in req.get("tools") or []:
        fn = t.get("function") or {}
        name = fn.get("name", "")
        if name not in KNOWN_TOOLS:
            return name  # e.g. pydantic-ai 'final_result'
    return None


def build_response(req: dict, mode: str) -> dict:
    """Produce the next scripted completion for the golden 3-step task."""
    messages = req.get("messages") or []

    if mode == "malformed":
        # Invalid args: query must be str, here it's an int -> validation error/retry.
        return completion(tool_call_msg("call_bad", SEARCH, {"query": 12345}), "tool_calls")

    done = tools_called_in(messages)
    if SEARCH not in done:
        return completion(
            tool_call_msg("call_search", SEARCH, {"query": "quarterly report"}),
            "tool_calls",
        )
    if ADD_TODO not in done:
        return completion(
            tool_call_msg(
                "call_todo",
                ADD_TODO,
                {"title": "Review quarterly report", "link": "https://notes.local/q3"},
            ),
            "tool_calls",
        )

    out = {"outcome": "done", "reason": "searched notes and added the todo"}
    output_tool = find_output_tool(req)
    if output_tool:
        return completion(tool_call_msg("call_final", output_tool, out), "tool_calls")
    return completion({"role": "assistant", "content": json.dumps(out)}, "stop")


def parse_http(conn: socket.socket) -> tuple[str | None, str | None]:
    """Read one HTTP/1.1 request off the connection, returning (path, body)."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            return None, None
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    lines = head.decode("latin1").split("\r\n")
    parts = lines[0].split(" ")
    path = parts[1] if len(parts) > 1 else "/"
    content_length = 0
    for h in lines[1:]:
        if h.lower().startswith("content-length:"):
            content_length = int(h.split(":", 1)[1].strip())
    body = rest
    while len(body) < content_length:
        chunk = conn.recv(4096)
        if not chunk:
            break
        body += chunk
    return path, body.decode("utf-8")


class Broker:
    """A scripted OpenAI-compatible broker bound to a Unix domain socket."""

    def __init__(self, sock_path: str, log_path: str, mode: str) -> None:
        self.sock_path = sock_path
        self.log_path = log_path
        self.mode = mode
        self.count = 0
        self.lock = threading.Lock()
        self._srv: socket.socket | None = None

    def handle(self, conn: socket.socket) -> None:
        """Serve one request: log it, script a response, send it back."""
        try:
            path, body = parse_http(conn)
            if path is None:
                return
            with self.lock:
                self.count += 1
                n = self.count
            log_request(self.log_path, n, path, body or "")
            try:
                req = json.loads(body) if body else {}
            except Exception:  # noqa: BLE001 — malformed body -> empty request
                req = {}
            payload = json.dumps(build_response(req, self.mode)).encode("utf-8")
            out = (
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: " + str(len(payload)).encode() + b"\r\n"
                b"Connection: close\r\n\r\n" + payload
            )
            conn.sendall(out)
        finally:
            conn.close()

    def serve_forever(self) -> None:
        """Bind, signal readiness, and accept connections until the socket closes."""
        if os.path.exists(self.sock_path):
            os.unlink(self.sock_path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock_path)
        srv.listen(64)
        self._srv = srv
        with open(self.sock_path + ".ready", "w") as f:
            f.write("ok")
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return  # socket closed on teardown
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def stop(self) -> None:
        """Close the listening socket, ending ``serve_forever``."""
        if self._srv is not None:
            try:
                self._srv.close()
            except OSError:
                pass


def start_in_thread(sock_path: str, log_path: str, mode: str = "normal") -> Broker:
    """Start a broker in a daemon thread and block until it signals readiness.

    Returns the ``Broker`` so the caller can ``stop()`` it on teardown.
    """
    open(log_path, "w").close()  # truncate the request log fresh
    broker = Broker(sock_path, log_path, mode)
    threading.Thread(target=broker.serve_forever, daemon=True).start()
    ready = sock_path + ".ready"
    for _ in range(200):  # up to ~2s
        if os.path.exists(ready):
            return broker
        time.sleep(0.01)
    raise RuntimeError(f"stub broker did not become ready at {sock_path}")


def main() -> None:
    """CLI entry: ``stub_broker.py <sock> <log> [mode]`` (blocking, for probes)."""
    import sys

    sock_path = sys.argv[1]
    log_path = sys.argv[2]
    mode = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("BROKER_MODE", "normal")
    open(log_path, "w").close()
    Broker(sock_path, log_path, mode).serve_forever()


if __name__ == "__main__":
    main()
