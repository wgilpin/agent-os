# Phase 1 Data Model: Deterministic Capability Rails

All entities are Elixir control-plane types (Principle V: structs + typespecs, no bare
maps). The Python side sees only the JSON refusal record (see `contracts/refusal-contract.md`).

## ActionTranscript (NEW — `lib/agent_os/action_transcript.ex`)

The ordered record of a run's tool activity, keyed by run token, persisted via
`StateStore`. In evaluation runs it is the judge's `observed_actions` input (FR-010).

| Field | Type | Notes |
|-------|------|-------|
| `run_token` | `String.t()` | binds the transcript to the broker-registered run |
| `mode` | `:live \| :record` | copied from the registration at first append |
| `entries` | `[TranscriptEntry.t()]` | append-only, chronological |

Operations (StateStore-backed, single writer):
- `clear(run_token)` — reset before an agent invocation (runner calls this)
- `append(run_token, entry)` — broker appends per gate decision / execution
- `read(run_token) :: ActionTranscript.t()` — judge/runner reads back

## TranscriptEntry (NEW)

One tool-channel event.

| Field | Type | Notes |
|-------|------|-------|
| `kind` | `:granted \| :rejected` | rejected = deterministic gate denial (FR-005) |
| `connector` | `String.t()` | the tool name the model requested |
| `method` | `String.t() \| nil` | requested/ resolved method, when applicable |
| `arguments` | `map()` | decoded tool-call arguments (never a credential) |
| `result` | `map() \| nil` | real result (live), synthetic `%{"status"=>"recorded"}` (record), or rejection reason |
| `reason_code` | `atom() \| nil` | for `:rejected` — `:ungranted_connector \| :ungranted_method \| :unknown_connector` |

**Validation**: `kind` and `connector` required; a `:rejected` entry MUST carry a
`reason_code`; `result` for a `:record`-mode `:granted` entry MUST be the synthetic success
shape (no external effect occurred).

## RefusalRecord (contract shape — Python stdout, mirrored by an Elixir parse)

The compliant "no action" / run-summary outcome (FR-006). Emitted by the agent on **exit 0**.

| Field | Type | Notes |
|-------|------|-------|
| `outcome` | `"completed" \| "refused"` | refused = agent chose empty/filtered actions |
| `reason` | `String.t()` | machine-readable justification (esp. for `refused`) |

Elixir side parses this into `{:ok, %{outcome: …, reason: …}}` or, on any parse failure /
abnormal exit, classifies the run as **malfunction** (not error).

## Verdict (CHANGED — `lib/agent_os/pipeline/stage3_judge.ex`)

Existing struct; `status` gains a fourth value.

| Field | Type | Change |
|-------|------|--------|
| `status` | `:pass \| :fail \| :error \| :malfunction` | **+`:malfunction`** — abnormal agent termination, distinct from a compliance verdict (`:pass`/`:fail`) and from a harness/broker fault (`:error`) (FR-007) |
| `reasoning` | `String.t()` | for `:pass`/`:fail`, references purpose-fit + refusal contract only (FR-013) |
| `disclaimer` | `String.t()` | unchanged |

Aggregation precedence over a test suite: `:error` (harness fault) ▸ `:malfunction` ▸
`:fail` ▸ `:pass` — a single harness fault still short-circuits; a malfunction is reported
distinctly and does not masquerade as a compliance fail.

## Broker registration entry (CHANGED — `InferenceBroker` token map)

The per-run-token value resolved by `resolve/1`.

| Field | Type | Change |
|-------|------|--------|
| `agent_name` | `String.t()` | unchanged |
| `manifest` | `Manifest.t()` | unchanged (agent-runtime token now bound to the **agent's** manifest, not the orchestrator's) |
| `mode` | `:live \| :record` | **NEW** — record mode drives FR-009 |
| `effective_model` | `String.t() \| nil` | **NEW** — when set, overrides `request.model` for routing + pricing (FR-012) |

`register/3` retained (defaults `mode: :live`, `effective_model: nil`); `register/4-5`
added for the record-mode / model-policy call sites.

## ToolDeclaration (registry metadata — `Connector.capability`)

Already present in the `capability` type as `tool_declaration :: map() | nil`. This feature
**populates** it for manifest-reachable connectors and makes a `nil` for a *granted*
connector a **loud generation failure** (FR-014), not a silent skip.

Example (`discord_notify`):

```elixir
tool_declaration: %{
  "type" => "function",
  "function" => %{
    "name" => "discord_notify",
    "description" => "Post a notification message to the pre-configured Discord webhook.",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "text" => %{"type" => "string", "description" => "The message content to post."}
      },
      "required" => ["text"]
    }
  }
}
```

Method is not a parameter here (single granted method `notify`); the broker gate resolves
and enforces it from `grant.methods`.

## Entity relationships

```text
Manifest.grants ──derives──▶ ToolDeclaration(s) ──injected by──▶ InferenceBroker call
                                                                        │
                              runtime model tool_calls ────────────────┘
                                        │ gate (connector + method scope)
                          ┌─────────────┴─────────────┐
                     :granted                     :rejected
                (live: execute / record: synthetic)  (typed reason)
                          └─────────────┬─────────────┘
                                        ▼
                               ActionTranscript(run_token)  ◀── clear/read by Stage-3 runner
                                        │
                                        ▼
                         Judge scoring (observed_actions) ──▶ Verdict{pass|fail|malfunction|error}
                                        ▲
                          RefusalRecord (agent stdout, exit 0)
```
