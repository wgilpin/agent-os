# Contract: Agent stdout → Run Worker (Outcome Record)

The single interface this feature touches: what a generated agent body prints to stdout,
and how the run worker interprets it. This replaces the retired `{"actions":[…]}` stdout
protocol.

## Producer

A generated agent body (Python), per the landed Stage-4 synthesis prompt. The body acts
only through the broker tool-call channel and, on completion, prints **exactly one line**
of JSON to stdout: the outcome record.

## Consumer

`AgentOS.RunWorker` (Elixir). It parses the line into an `OutcomeRecord`, then reads the
`ActionTranscript` for the run token to learn what the agent did.

## Message format

Single line, UTF-8, JSON object:

```json
{"outcome": "completed", "reason": "handled via tool channel"}
```

### Fields

| Key       | Type   | Required | Meaning                                             |
|-----------|--------|----------|-----------------------------------------------------|
| `outcome` | string | yes      | Terminal disposition, e.g. `completed`, `refused`.  |
| `reason`  | string | yes      | Human-readable explanation for the run log.         |

### Examples the consumer MUST accept

```json
{"outcome": "completed", "reason": "handled via tool channel"}
{"outcome": "refused", "reason": "out of scope"}
{"outcome": "completed", "reason": ""}
```

### Inputs the consumer MUST reject as malformed

| Input                                          | Why rejected                     |
|------------------------------------------------|----------------------------------|
| `{"actions": []}`                              | Retired protocol; no `outcome`.  |
| `{"outcome": "completed"}`                     | Missing `reason`.                |
| `{"reason": "x"}`                              | Missing `outcome`.               |
| `{"outcome": 1, "reason": "x"}`                | `outcome` not a string.          |
| `not json`                                     | Unparseable.                     |
| `` (empty stdout, process exited 0)            | No record.                       |

## Consumer behavior

| Condition                              | Run-log status | Notes                                       |
|----------------------------------------|----------------|---------------------------------------------|
| Valid outcome record, spend < cap      | `:ok`          | Tally (approved/parked/rejected/gate_reasons) from transcript. |
| Valid outcome record, spend ≥ cap      | breach path    | `dispatch_on_breach`; counts from transcript. |
| Malformed record                       | `:error`       | `failure_cause: "malformed_outcome"`; transcript effects left intact. |
| Port crash / OOM / timeout (pre-parse) | `:error`       | Existing `failure_cause` mapping; unchanged. |

## Invariants

- The consumer does **not** execute, gate, re-park, or re-charge any effect described by
  the transcript — the rail already did so during inference (exactly-once).
- The outcome record carries **no** action data; it is disposition only.
- Clean cutover: there is no compatibility mode for the legacy `actions` shape.
