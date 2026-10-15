#!/usr/bin/env python3
"""Stub inference broker for the agent-framework bake-off.

A minimal HTTP/1.1 server on a Unix domain socket that speaks OpenAI
chat-completions JSON. It mirrors the real agent_os InferenceBroker UDS
listener (lib/agent_os/inference_broker.ex): AF_UNIX, HTTP/1.1, POST with a
JSON body. It accepts BOTH /v1/inference and /v1/chat/completions.

It is SCRIPTED by conversation state (not a blind counter) so it is robust to
each framework's message threading:

  * no search_notes result yet  -> return a tool_call for search_notes(query)
  * search_notes done, no add_todo yet -> return a tool_call for add_todo(title, link)
  * both tools done             -> return the FINAL answer. If the request's
                                   `tools` array contains an output/result tool
                                   (e.g. pydantic-ai's `final_result`), the final
                                   answer is emitted as a tool_call to it with
                                   {outcome, reason}; otherwise as plain JSON content.

Every request is logged (count + path + full body) as one JSONL line to the
log path, which is how we detect hidden/uncommanded calls and retries.

Modes (BROKER_MODE env or 3rd argv):
  * normal    -> the 3-step golden script above.
  * malformed -> ALWAYS returns a search_notes tool_call whose arguments are
                 invalid (query is an int, and a required field is missing),
                 so a validating framework rejects it. Used to count retries.

Usage: broker.py <sock_path> <log_path> [mode]
"""
import json
import os
import socket
import sys
import threading
import time

SEARCH = "search_notes"
ADD_TODO = "add_todo"
KNOWN_TOOLS = {SEARCH, ADD_TODO}


def log_request(log_path, n, path, body):
    rec = {"n": n, "ts": time.time(), "path": path, "body": body}
    with open(log_path, "a") as f:
        f.write(json.dumps(rec) + "\n")


def tool_call_msg(call_id, name, args_obj):
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


def completion(message, finish_reason):
    return {
        "id": "chatcmpl-stub",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": "stub-model",
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
        "usage": {"prompt_tokens": 20, "completion_tokens": 10, "total_tokens": 30},
    }


def tools_called_in(messages):
    """Return the set of known tool names that already have a tool result in history."""
    done = set()
    # Map tool_call_id -> name from prior assistant messages.
    id_to_name = {}
    for m in messages:
        if not isinstance(m, dict):
            continue
        for tc in m.get("tool_calls") or []:
            fn = (tc.get("function") or {})
            id_to_name[tc.get("id")] = fn.get("name")
        if m.get("role") == "tool":
            name = m.get("name") or id_to_name.get(m.get("tool_call_id"))
            if name in KNOWN_TOOLS:
                done.add(name)
    return done


def find_output_tool(req):
    """Return the name of an output/result tool the framework registered, if any."""
    for t in req.get("tools") or []:
        fn = (t.get("function") or {})
        name = fn.get("name", "")
        if name not in KNOWN_TOOLS:
            return name  # e.g. pydantic-ai 'final_result'
    return None


def build_response(req, mode):
    messages = req.get("messages") or []

    if mode == "malformed":
        # Invalid args: query must be str, here it's an int; and we omit nothing
        # else but wrong-typed required field forces a validation error/retry.
        return completion(
            tool_call_msg("call_bad", SEARCH, {"query": 12345}),
            "tool_calls",
        )

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

    # Final answer.
    out = {"outcome": "done", "reason": "searched notes and added the todo"}
    output_tool = find_output_tool(req)
    if output_tool:
        return completion(
            tool_call_msg("call_final", output_tool, out),
            "tool_calls",
        )
    return completion(
        {"role": "assistant", "content": json.dumps(out)},
        "stop",
    )


def parse_http(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            return None, None
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    head_txt = head.decode("latin1")
    lines = head_txt.split("\r\n")
    request_line = lines[0]
    parts = request_line.split(" ")
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
    def __init__(self, sock_path, log_path, mode):
        self.sock_path = sock_path
        self.log_path = log_path
        self.mode = mode
        self.count = 0
        self.lock = threading.Lock()

    def handle(self, conn):
        try:
            path, body = parse_http(conn)
            if path is None:
                return
            with self.lock:
                self.count += 1
                n = self.count
            log_request(self.log_path, n, path, body)
            try:
                req = json.loads(body) if body else {}
            except Exception:
                req = {}
            resp = build_response(req, self.mode)
            payload = json.dumps(resp).encode("utf-8")
            out = (
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: " + str(len(payload)).encode() + b"\r\n"
                b"Connection: close\r\n\r\n" + payload
            )
            conn.sendall(out)
        finally:
            conn.close()

    def serve(self):
        if os.path.exists(self.sock_path):
            os.unlink(self.sock_path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock_path)
        srv.listen(64)
        # Signal readiness.
        with open(self.sock_path + ".ready", "w") as f:
            f.write("ok")
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()


def main():
    sock_path = sys.argv[1]
    log_path = sys.argv[2]
    mode = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("BROKER_MODE", "normal")
    # Truncate log fresh.
    open(log_path, "w").close()
    Broker(sock_path, log_path, mode).serve()


if __name__ == "__main__":
    main()
