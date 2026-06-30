# Data Model: Stage 4 Write the Novel Agent Body

## `AgentOS.Pipeline.Stage4.GeneratedFile`

One file the synthesis call proposed to write.

| Field | Type | Notes |
|---|---|---|
| `path` | `String.t()` | Bare relative filename within `agents/<agent_name>/` — no `/`, no `..`, must end `.py` (path-safety guard). |
| `content` | `String.t()` | Full file source text as returned by the model. |

```elixir
defstruct [:path, :content]

@type t :: %__MODULE__{path: String.t(), content: String.t()}
```

## `AgentOS.Pipeline.Stage4.AgentBody`

The root structure of a successful synthesis result — mirrors `Stage3.TestSpec`'s role as the
typed wrapper returned from `generate/3` before any side effect (file write) happens.

| Field | Type | Notes |
|---|---|---|
| `agent_name` | `String.t()` | The provisioning name; determines the write target `agents/<agent_name>/`. |
| `purpose` | `String.t()` | Copied from `manifest.purpose` at generation time, for traceability in the return value (not written into any emitted file). |
| `files` | `[GeneratedFile.t()]` | Expected to contain exactly `main.py` and `models.py` after the contract-presence guard passes; the type itself does not constrain the list to two entries (rejected entries are a guard failure, not a type-level cardinality, since cardinality is a content invariant, not a structural one). |

```elixir
defstruct [:agent_name, :purpose, :files]

@type t :: %__MODULE__{
        agent_name: String.t(),
        purpose: String.t(),
        files: [GeneratedFile.t()]
      }
```

## Inputs (not new structs — existing types reused)

| Name | Type | Source |
|---|---|---|
| `agent_name` | `String.t()` | Caller-supplied (the agent identity being generated for). |
| `manifest` | `AgentOS.Manifest.t()` | Stage 2 output (`AgentOS.Manifest.Projection`); the **sole** structured input besides `agent_name` — `manifest.purpose` supplies the confirmed-purpose value, so there is no separate "purpose" parameter (FR-002: purpose + manifest are the only inputs, and purpose lives on the manifest already). |

## Guard Failure Reasons (tagged errors, not a struct — listed for completeness)

| Reason atom | Triggered by |
|---|---|
| `:missing_run_token` | No `:run_token` opt supplied (mirrors Stage 3). |
| `:spend_breach` | Broker reports `{:breach, :spend}` during the authoring call. |
| `:invalid_synthesis_output` | Broker completion is not valid JSON, or does not match the `{"files": [...]}` shape. |
| `:unsafe_path` | A `GeneratedFile.path` fails the path-safety guard. |
| `:missing_typed_contract` | `main.py` content fails the contract-presence guard. |
| `:manifest_leak_detected` | Concatenated content contains a manifest-literal or credential-shaped pattern. |
| `:direct_provider_path_detected` | Concatenated content references a provider hostname/SDK or performs non-`INFERENCE_SOCKET` network I/O. |
| `:invalid_python_syntax` | A `.py` file fails the `ast.parse` syntax check. |
| `:write_failed` | A filesystem write of an already-guard-passed file fails. |

These reasons are not persisted (no new StateStore collection — see plan.md's Constitution Check,
Principle IX row); they are returned to the caller as `{:error, reason}` and logged via `Logger`
per Constitution VI at the point of failure.

## Relationships to Existing Entities

```text
ElicitedSpec (Stage 1, confirmed: true)
        │  (Stage 2: pure projection)
        ▼
AgentOS.Manifest  ──────────────┐
        │ (purpose + grants)    │ (Stage 3, independently: judge_spec.json — NEVER read by Stage 4)
        ▼                        │
AgentOS.Pipeline.Stage4.generate/3
        │ (one InferenceBroker.complete/2 call; static guards; all-or-nothing write)
        ▼
agents/<agent_name>/main.py + models.py   (untrusted workload; runs later behind the unchanged v2 gate)
```

No existing entity is modified by this feature. `AgentOS.Manifest` is read-only input;
`AgentOS.InferenceBroker` is called exactly as Stage 3 already calls it (no new broker API).
