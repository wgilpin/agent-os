# Data Model: Optional Inference for Generated Agents

**Feature**: 040-optional-inference | **Date**: 2026-07-07

All new boundary data is strongly typed (Constitution V). Existing structs are
extended, never replaced; no bare-map contracts are introduced.

## New: `AgentOS.ExecutionMode`

The typed per-purpose classification, decided once before synthesis and recorded
with the agent's artifacts.

| Field       | Type                          | Notes                                             |
|-------------|-------------------------------|---------------------------------------------------|
| `mode`      | `:deterministic \| :inference` | The two-value classification. Never a bare string. |
| `rationale` | `String.t()`                  | Why the classifier chose this mode (legibility).   |

Functions:
- `classify(agent_name, manifest, opts)` → `{:ok, t()} | {:error, reason}` — one
  broker completion ("does fulfilling this purpose require reasoning over dynamic
  content at runtime?"); `provider_fn`-stubbed in tests. Unparseable/ambiguous
  classifier output resolves to `%ExecutionMode{mode: :inference}` (safe default,
  logged loudly).
- `store(agent_name, t(), opts)` / `load(agent_name, opts)` — sidecar JSON at
  `agents/<agent_name>/execution_mode.json`. `load/2` on a missing file returns
  `{:ok, %ExecutionMode{mode: :inference, rationale: "pre-040 agent (default)"}}`
  so existing deployed agents need no migration.

Sidecar file shape:
```json
{"mode": "deterministic", "rationale": "fixed notification; no runtime reasoning"}
```

State transitions: none — written once per generation run; regenerating an agent
overwrites it.

## New: `AgentOS.ToolSubmission`

The typed parse of a `/v1/tool_calls` request body, validated before anything
reaches the rail.

| Field        | Type                | Notes                                                  |
|--------------|---------------------|--------------------------------------------------------|
| `run_token`  | `String.t()`        | Resolved via `InferenceBroker.resolve/1`; 401 if unknown. |
| `tool_calls` | `[tool_call_map()]` | OpenAI-shaped: `{"id", "function" => {"name", "arguments"}}` — the exact shape `CapabilityRail.evaluate_tool_calls/4` already consumes. |

Validation rules:
- Body must decode as JSON with a binary `run_token` and a list `tool_calls`
  → otherwise HTTP 400, nothing evaluated, error logged with context.
- Each element missing a resolvable `function.name` is still passed to the rail,
  which records it `:rejected` (`:unknown_connector`) — malformed *calls* are
  recorded, malformed *requests* are refused (FR-003 vs edge case).
- An empty `tool_calls` list is valid: evaluates to an empty result set (the run's
  terminal outcome reflects "nothing submitted").

## New: channel response (typed, encoded to JSON)

Per-call result derived from the rail's tool messages + transcript dispositions:

| Field     | Type                                   | Notes                                  |
|-----------|----------------------------------------|-----------------------------------------|
| `results` | `[%{id, name, disposition, content}]`  | `disposition ∈ "executed" \| "rejected" \| "parked"`; `content` is the same string the inference path would feed back as the tool message. |

HTTP mapping: `200` results · `402 {"error": "spend_breach"}` · `401
{"error": "unknown_run_token"}` · `400 {"error": "bad_request"}`.

## Extended: `AgentOS.Pipeline.Stage4.AgentBody`

| Field            | Type                    | Change                                  |
|------------------|-------------------------|------------------------------------------|
| `agent_name`     | `String.t()`            | unchanged                                |
| `purpose`        | `String.t()`            | unchanged                                |
| `files`          | `[GeneratedFile.t()]`   | unchanged                                |
| `execution_mode` | `ExecutionMode.t()`     | **NEW** — the mode this body was synthesized under. |

## Unchanged (relied upon, verified against source)

- **`AgentOS.ActionTranscript.Entry`** — `kind :: :granted | :parked | :rejected`,
  plus connector/method/arguments/result/reason_code. The direct channel introduces
  no new entry kind and no new writer: only the rail appends, keyed by run token
  (Constitution IX). "executed" in the channel response maps to a `:granted` entry.
- **`AgentOS.Manifest`** — no schema change. Execution mode deliberately lives in
  the sidecar, not the manifest (see research.md D5).
- **Spend ledger entry** (`%{spent, window_start}`) — the channel persists
  accumulated tool cost through the same `{:put, agent_name, entry}` action the
  inference path uses. Deterministic runs add zero inference charges by
  construction (no completion ever happens on this path).
- **`AgentOS.Pipeline.Stage3.TestSpec` / `TestCase` / `Verdict`** — shapes
  unchanged; only prompt *content* migrates (no retired-protocol expectations).
  The declared mode is an input to spec synthesis, not a new spec field.

## Relationships

```
ElicitedSpec ──Stage2──▶ Manifest (unchanged, privileged-read)
                             │
                 Orchestrator: ExecutionMode.classify (manifest+purpose only)
                             │            │
              ┌──────────────┴──┐    sidecar: agents/<name>/execution_mode.json
              ▼                 ▼
    Stage4.generate(mode)   Stage3.generate/run(mode)
       │ deterministic:          judge asserts vs declared mode,
       │   body → /v1/tool_calls    containment read from transcript
       │ inference:
       │   body → /v1/inference
       ▼
  InferenceBroker (UDS) ──▶ CapabilityRail.evaluate_tool_calls ──▶ ActionTranscript
        (both routes)          (sole gate, sole transcript writer)   (single writer,
                                                                      keyed by run token)
```
