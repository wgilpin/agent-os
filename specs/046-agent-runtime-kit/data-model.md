# Phase 1 — Data Model

The kit adds no persistent storage. These are the in-flight data shapes crossing the port and UDS boundaries. Python shapes are Pydantic models (Constitution V — no bare dicts).

## Environment contract (input, sandbox-injected)

Consumed **only** by the kit (`substrate_model`); the body never reads these (FR-002).

| Var | Meaning | Missing/empty behaviour |
|---|---|---|
| `INFERENCE_SOCKET` | Absolute path to the broker UDS inside the container | Fail fast, structured error outcome (FR-009) |
| `RUN_TOKEN` | Per-run capability token; becomes the OpenAI `api_key` → `Authorization: Bearer` | Fail fast |
| `AGENT_MODEL` | Model id the broker prices/forwards | Fail fast |

Validation: all three non-empty at `substrate_model()` call time. `INFERENCE_SOCKET` length checked against the AF_UNIX `sun_path` limit (~104 chars on macOS); over-limit → clear error, not an opaque OS failure.

## InvocationPayload (stdin, one JSON line in)

```python
class InvocationPayload(BaseModel):
    # The task input the body prompts on. Kept permissive: existing run_worker
    # payloads carry {"roster": …, "trigger_input": …}; the sample body reads
    # the fields it needs. Extra keys are ignored (model_config extra="allow"
    # or an explicit task field per the sample body's needs).
    task: str | None = None
    history: list[dict] | None = None  # prior conversation messages (opaque-but-JSON), optional
```

- `history` absent → fresh run (FR-006 / US3-1).
- `history` present → deserialized via pydantic-ai's `ModelMessagesTypeAdapter` and passed as `message_history=` (US3-2).
- `history` malformed (not a list, or not valid message structures) → fail fast, structured error outcome; **no silent truncation** (FR-009 / US3-3).

## OutcomeRecord (stdout, one JSON line out)

```python
class OutcomeRecord(BaseModel):
    outcome: str          # "completed" | "failed" (or task-specific success token)
    reason: str           # human-legible one-liner
    history: list[dict]   # NEW messages produced by THIS run (the delta), opaque-but-JSON
```

- Success → `outcome="completed"`, `reason=<summary>`, `history=<result.new_messages() serialized>`.
- Any failure (env incomplete, broker unreachable, malformed history, retry exhaustion) → `outcome="failed"`, `reason=<diagnosable cause>`, `history=[]` (or the partial delta if a run started). Never exits without emitting a record (FR-009).
- **Elixir compatibility**: `AgentOS.OutcomeRecord.parse/1` matches `%{"outcome" => …, "reason" => …}` and tolerates the extra `history` key — no Elixir-side change (see research §Decision 5).

## OpenAI chat-completions request (kit → broker, over UDS)

Emitted by pydantic-ai's OpenAI provider; the kit does not hand-assemble it.

```jsonc
POST /v1/chat/completions HTTP/1.1
Authorization: Bearer <RUN_TOKEN>
Content-Type: application/json

{
  "model": "<AGENT_MODEL>",
  "messages": [ {"role":"system","content":…}, {"role":"user","content":…}, … ],
  "tools":    [ {"type":"function","function":{…}}, … ]   // framework-declared (plain in-body tools + final_result)
}
```

## OpenAI chat-completion response (broker → kit)

One metered turn. Either a tool-call turn or a final answer.

```jsonc
{
  "id": "chatcmpl-…",
  "object": "chat.completion",
  "model": "<model>",
  "choices": [ { "index":0,
                 "message": {"role":"assistant","content":null,
                             "tool_calls":[{"id":…,"type":"function",
                                            "function":{"name":…,"arguments":"{…}"}}]},
                 "finish_reason": "tool_calls" } ],
  "usage": { "prompt_tokens": N, "completion_tokens": M, "total_tokens": N+M }
}
```

`usage` is what the broker meters into micro-dollars (identical to the native path). The framework consumes `choices[0].message`; the broker cares only about `usage` for cost.

## Broker error responses on the new surface

Same status codes / semantics as the native path (US2).

| Condition | HTTP status | Body | Metered? |
|---|---|---|---|
| Valid token, priced model, under cap | 200 | OpenAI completion | Yes (one call) |
| Missing/malformed/expired Bearer token | 401 | `{"error":"unknown_run_token"}` | No upstream call, no spend |
| At/over per-call cap or aggregate budget | 402 | `{"error":"spend_breach"}` | Kill-on-breach as native |
| Unpriced model | 400 | `{"error":"unpriced_model"}` | No |
| Malformed request / unsupported feature (e.g. `stream:true`) | 400 | `{"error":…}` | No |

## SpendLedger entry (unchanged, reused)

`%{spent: micro_dollars :: non_neg_integer, window_start: DateTime}` keyed by `agent_name` in the `spend_ledger` StateStore — the identical structure and single-writer path the native envelope uses. The OpenAI surface writes it through the same `{:put, agent_name, entry}` action. No new fields.
