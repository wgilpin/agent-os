# Contract: Direct Tool-Submission Channel (`/v1/tool_calls`)

**Boundary**: sandboxed agent process → substrate (InferenceBroker UDS listener).
The agent side sees only `INFERENCE_SOCKET` + `RUN_TOKEN` env vars — identical to
the inference path. No credential, no manifest, no capability list crosses this
boundary in either direction.

## Request

HTTP/1.1 over the existing Unix domain socket (same framing as `/v1/inference`):

```
POST /v1/tool_calls HTTP/1.1
Content-Type: application/json
Content-Length: <n>
Connection: close

{
  "run_token": "<RUN_TOKEN env value>",
  "tool_calls": [
    {
      "id": "call_1",
      "function": {
        "name": "discord_notify",
        "arguments": "{\"text\": \"Hello, World!\"}"
      }
    }
  ]
}
```

- `tool_calls` uses the exact OpenAI-style shape the rail already parses on the
  inference path; `function.arguments` is a JSON-encoded string.
- Multiple calls allowed; evaluated in order, each gated and recorded individually
  (partial success is possible and visible per call).
- Empty `tool_calls` is valid → `200 {"results": []}`.

## Routing rule (backward compatibility)

The UDS handler parses the request path. `/v1/tool_calls` → this contract.
**Any other path (including `/v1/inference` and legacy pathless requests) keeps
today's behavior** (`InferenceBroker.complete/2`), so deployed agents are untouched.

## Processing guarantees (identical to the inference path)

Every submitted call passes through `CapabilityRail.evaluate_tool_calls/4` — the
same gate, in the same order, with the same recorded dispositions:

| Case | Rail behavior | Transcript entry | Metering |
|------|---------------|------------------|----------|
| Granted connector + granted method | Executed (credential held by substrate only) | `:granted` with result | Connector cost added to spend ledger |
| Granted, but connector execution fails | Attempted; failure isolated | `:granted` with error result (disposition `"error"`) | Connector cost still metered (existing rail semantics) |
| Ungranted connector | Not executed | `:rejected` (`:ungranted_connector`) | none |
| Granted connector, ungranted method | Not executed | `:rejected` (`:ungranted_method`) | none |
| Unknown connector name | Not executed | `:rejected` (`:unknown_connector`) | none |
| Approval-required connector | Not executed; queued in `pending_approvals` | `:parked` | none until approved |
| Broker registered `:record`, args match the tool declaration (judge runs) | Synthetic success, no execution | `:granted` (`{"status": "recorded"}`) | zero cost |
| Broker registered `:record`, args violate the tool declaration | Not executed; args are schema-validated (every `required` name present; every key a declared property or `"method"`) even in record mode, so schema drift can't fake success and fool the judge | `:rejected` (`:invalid_arguments`) | none |
| Cumulative cost would cross the cap | Halt | — | `402 spend_breach` |

**No model call occurs anywhere on this path.** Zero inference charges by
construction.

## Response

`200 OK`:
```json
{
  "results": [
    {"id": "call_1", "name": "discord_notify", "disposition": "executed", "content": "..."}
  ]
}
```
`disposition ∈ "executed" | "error" | "rejected" | "parked"`; `content` is the same
feedback string the inference path returns as a tool message (error text for
rejections/failures, parked notice for parked calls). `"error"` means the call was
granted but its execution failed — a deterministic body must not report success.

Errors:
- `400 {"error": "bad_request"}` — body not JSON, or missing `run_token` /
  `tool_calls` list. Nothing evaluated; logged with context.
- `401 {"error": "unknown_run_token"}` — token not registered.
- `402 {"error": "spend_breach"}` — cap already reached, or would be crossed.

## Invariants under test

1. Three-way disposition test (granted / ungranted / approval-required) matches the
   inference path's transcript output for the same calls, byte-for-byte on
   `kind`/`connector`/`reason_code`.
2. Only the rail writes the transcript; the channel adds no writer (single-writer,
   keyed by run token).
3. A run using only this channel records zero inference spend; ledger delta equals
   the sum of executed connector costs exactly.
4. No response ever contains a credential, a recipient allowlist, a spend cap, or
   any capability beyond the feedback string the inference tool-message already
   exposes.
