# Research: Synchronous Tools + Web Search

## 1. Tool Loop Integration Design

The primary design question was where to host the recursive tool call loop.
- **Option A (Agent container-side)**: The agent runs the loop. The agent container calls the broker, gets a tool call request, runs the tool (how? agent doesn't have credentials/network), and calls the broker again. This violates Principle XI (No ambient authority / credential holder in container) and Principle IX (Substrate owns lifecycle).
- **Option B (Substrate-side chokepoint)**: The loop resides completely inside the `AgentOS.InferenceBroker`. When the agent requests completion, the broker intercepts tool requests, executes them in-process, constructs the history, and handles subsequent LLM calls. This is the **selected approach** because it keeps the agent process simple and maintains credential/execution isolation.

## 2. API Signature & Mock Compatibility

Currently, tests define mock `provider_fn` closures with arity 3: `fn model, messages, secret -> ...`.
To prevent breaking existing tests while allowing the real provider (and new tests) to receive tool definitions, we use dynamic arity inspection:
- If `provider_fn` is arity 4: Call `provider_fn.(model, messages, tools, secret)`.
- If `provider_fn` is arity 3: Call `provider_fn.(model, messages, secret)`.

This keeps all 40+ existing tests fully operational without modification.

## 3. Schema Construction & Formats

OpenRouter accepts tool declarations matching the OpenAI Chat Completions API format:
```json
{
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "web_search",
        "description": "Search the web for a query",
        "parameters": {
          "type": "object",
          "properties": {
            "query": {
              "type": "string",
              "description": "The search query"
            }
          },
          "required": ["query"]
        }
      }
    }
  ]
}
```

When a tool call is executed, we append an `assistant` message containing the `tool_calls` array, followed by a `tool` response message for each call:
```json
{
  "role": "tool",
  "tool_call_id": "call_123",
  "name": "web_search",
  "content": "Result content..."
}
```

## 4. Spend Control & Fault Isolation

- **Metering**: Tool connector metadata defines `cost` in micro-dollars. Prior to calling `execute_tool/2`, the broker checks the spend ledger. If the cost exceeds the remaining spend cap, the tool call is blocked and a `:spend_breach` is returned. If it succeeds, the cost is added to the ledger.
- **Fault Containment**: Spawning the tool execution under `AgentOS.ConnectorSupervisor` via `Task.Supervisor.async_nolink` isolates the runner. Any timeout (5s) or crash is caught and returned as a `"Error: ..."` string in the tool response, allowing the model to decide how to handle it, without crashing the broker or the run worker.
