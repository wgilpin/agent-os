# Contract: Run-Input Delivery & Trigger Provenance

How an event payload / message content reaches the fired run as its hand-input, and how each fire is made
attributable in the run-log. Thin edits to the existing `RunSupervisor → RunWorker → build_payload` path;
no port-protocol change.

## Input threading

```text
TriggerGateway
  → RunSupervisor.start_run(trigger: <provenance>, trigger_input: <payload|content>, agent: <name>)
    → RunWorker.run_once(opts)            # reads Keyword.get(opts, :trigger_input)
      → build_payload(snapshot, items)    # includes trigger_input as one optional JSON field
        → PortRunner.run(input_json, ...) # existing single stdin line, unchanged protocol
```

- `:trigger_input` is **optional**. Absent (timer/manual fires) ⇒ payload is exactly as today; the new
  field is omitted or `null`.
- The field is delivered to the agent as untrusted input — the agent treats it like sanitized bookmark
  input; the substrate makes no trust claim about its *content* (only about its *origin*, R1).
- No change to the stdin-guard wrapper or the one-line port protocol (Constitution I).

### Agent side (`agents/discovery/main.py`)

Read the optional field from the existing stdin JSON object (e.g. `payload.get("trigger_input")`). One
field; no new agent logic, no model call. Behaviour with the field absent is unchanged.

## Provenance values (run-log `trigger=`)

`RunWorker` already stamps `trigger=` and `RunLog` already parses it. The accepted value set is extended:

| Provenance | Emitted when |
|------------|--------------|
| `timer` | Scheduler daily fire (existing) |
| `manual` | `Scheduler.run_now(:manual, …)` (existing) |
| `event:<name>` | `TriggerGateway` event fire; carries the matched event name |
| `message` | `TriggerGateway` message fire |
| `approval-resume` | a held action executed/denied via approval (no new agent run) |

`RunWorker`/`RunLog` must format an `event:<name>` provenance correctly (string value containing the name);
`Inventory`'s `trigger=` extraction already tolerates an arbitrary non-space token
([inventory.ex:123](../../lib/agent_os/inventory.ex)) — confirm `event:<name>` carries no spaces (event
names are single tokens; reject names with whitespace at intake).

## Guarantees

- One `start_run` per admitted event-per-matching-agent / per message ⇒ one run, attributable to its
  trigger from the run-log alone (FR-011, FR-013, Principle VIII).
- The fired run still goes through the gate, credential proxy, and spend metering unchanged (FR-015).

## Test contract

- `run_log_test.exs`: a run stamped `trigger: "event:bookmark_saved"` round-trips through append+parse with
  the name intact; `trigger: "message"` and `trigger: "approval-resume"` likewise.
- `inventory_test.exs`: last-run trigger renders these provenance values; pending approvals are listed.
- Worker-level (injected `worker_fn` in `trigger_gateway_test.exs`): `:trigger_input` is threaded through to
  the worker opts.
