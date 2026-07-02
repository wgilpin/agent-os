# Quickstart: Synchronous Tools + Web Search

This guide shows how to run and verify the synchronous tool-use channel and the `web_search` connector.

## 1. Running Tests

To verify the implementation without making remote API calls:

```bash
# Run all tests to make sure there are no regressions
mix test

# Run only the inference broker tests (which will include the new tool capability tests)
mix test test/agent_os/inference_broker_test.exs
```

## 2. Dynamic Tool Execution Example

An agent sends a request over the UDS socket that prompts the model to call the `web_search` tool:

```python
import json
import socket

# UDS Socket setup
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("data/inference.sock")

payload = {
    "run_token": "valid_run_token_with_web_search_grant",
    "model": "gemini-3-flash-preview",
    "messages": [
        {"role": "user", "content": "What is the current price of gold? Search the web."}
    ]
}
body = json.dumps(payload)

request = (
    f"POST /v1/inference HTTP/1.1\r\n"
    f"Content-Type: application/json\r\n"
    f"Content-Length: {len(body)}\r\n\r\n"
    f"{body}"
)
s.sendall(request.encode())

response = s.recv(4096)
print(response.decode())
```

The `InferenceBroker` automatically:
1. Advertises the `web_search` tool schema to the model.
2. Intercepts the model's tool call request.
3. Resolves the `SEARCH_API_KEY` credential post-approval.
4. Executes the search tool synchronously.
5. Injects the result back into context.
6. Returns the final text response to the agent.
