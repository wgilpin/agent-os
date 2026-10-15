"""No-framework baseline: typed tool loop over the UDS broker, stdlib + pydantic only.

Transport is raw HTTP/1.1 over AF_UNIX — the same wire code the real generated
agents use today (agents/*/main.py) — so this candidate has ZERO HTTP deps.

Run:  run_nofw.py <sock> <log> <mode>
Prints a JSON metrics line to stdout as NOFW_RESULT=<json>.
"""
import json
import os
import socket
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "harness"))
import socket_guard  # noqa: E402

from pydantic import BaseModel, ValidationError  # noqa: E402

SOCK = sys.argv[1]
LOG = sys.argv[2]
MODE = sys.argv[3] if len(sys.argv) > 3 else "normal"

MAX_TURNS = 8
MAX_VALIDATION_RETRIES = 2  # parity with the pydantic-ai candidate (retries=2)


# ---------- transport (the part a runtime kit would own) ----------

def post_uds(sock_path: str, path: str, payload: dict) -> dict:
    body = json.dumps(payload)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    req = (
        f"POST {path} HTTP/1.1\r\n"
        f"Host: localhost\r\nContent-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n{body}"
    )
    s.sendall(req.encode())
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    s.close()
    head, _, resp_body = data.decode().partition("\r\n\r\n")
    status = int(head.split("\r\n")[0].split(" ")[1])
    if status != 200:
        raise RuntimeError(f"broker status {status}")
    return json.loads(resp_body)


# ---------- typed tools ----------

class SearchNotesArgs(BaseModel):
    model_config = {"extra": "forbid"}
    query: str


class AddTodoArgs(BaseModel):
    model_config = {"extra": "forbid"}
    title: str
    link: str


class Result(BaseModel):
    model_config = {"extra": "forbid"}
    outcome: str
    reason: str


tool_hits = []


def search_notes(args: SearchNotesArgs) -> str:
    """Search the user's notes for a query string."""
    tool_hits.append(("search_notes", args.query))
    return "found 3 notes matching the query"


def add_todo(args: AddTodoArgs) -> str:
    """Add a todo item with a title and a link."""
    tool_hits.append(("add_todo", args.title, args.link))
    return "todo added"


TOOLS = {
    "search_notes": (SearchNotesArgs, search_notes),
    "add_todo": (AddTodoArgs, add_todo),
}


def tool_schema(name: str, model: type[BaseModel], description: str) -> dict:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": model.model_json_schema(),
            "strict": True,
        },
    }


TOOLS_PAYLOAD = [
    tool_schema("search_notes", SearchNotesArgs, "Search the user's notes for a query string."),
    tool_schema("add_todo", AddTodoArgs, "Add a todo item with a title and a link."),
    tool_schema("final_result", Result, "The final response which ends this conversation"),
]


# ---------- the loop ----------

def run_agent() -> Result:
    messages = [
        {
            "role": "system",
            "content": "Search the user's notes, then add a todo. "
                       "Finish by reporting the outcome.",
        },
        {"role": "user", "content": "Prepare my quarterly review."},
    ]
    validation_retries = 0
    for _ in range(MAX_TURNS):
        resp = post_uds(SOCK, "/v1/chat/completions", {
            "messages": messages,
            "model": "stub-model",
            "stream": False,
            "tool_choice": "required",
            "tools": TOOLS_PAYLOAD,
        })
        msg = resp["choices"][0]["message"]
        tool_calls = msg.get("tool_calls") or []
        if not tool_calls:
            return Result.model_validate_json(msg.get("content") or "{}")
        messages.append(msg)
        for tc in tool_calls:
            name = tc["function"]["name"]
            raw_args = tc["function"]["arguments"]
            if name == "final_result":
                return Result.model_validate_json(raw_args)
            if name not in TOOLS:
                raise RuntimeError(f"model called unknown tool {name!r}")
            args_model, fn = TOOLS[name]
            try:
                out = fn(args_model.model_validate_json(raw_args))
            except ValidationError as e:
                validation_retries += 1
                if validation_retries > MAX_VALIDATION_RETRIES:
                    raise RuntimeError(f"exceeded {MAX_VALIDATION_RETRIES} validation retries") from e
                out = (f"{e.error_count()} validation error(s):\n{e.json(indent=2)}\n\n"
                       "Fix the errors and try again.")
            messages.append({"role": "tool", "tool_call_id": tc["id"], "content": out})
    raise RuntimeError(f"no final answer within {MAX_TURNS} turns")


def main():
    socket_guard.install()
    result = {"candidate": "no-framework baseline", "mode": MODE}
    try:
        out = run_agent()
        result["status"] = "PASS"
        result["output"] = out.model_dump()
        result["output_type_ok"] = isinstance(out, Result)
        result["tool_hits"] = tool_hits
    except Exception as e:
        result["status"] = "FAIL"
        result["error"] = f"{type(e).__name__}: {e}"
        result["tool_hits"] = tool_hits
    result["egress_attempts"] = socket_guard.ATTEMPTS
    print("NOFW_RESULT=" + json.dumps(result))


if __name__ == "__main__":
    main()
