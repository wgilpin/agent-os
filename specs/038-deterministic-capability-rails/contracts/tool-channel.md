# Contract: Structured Tool-Call Channel & Deterministic Gate

The single runtime action path for generated agents. Owned by `AgentOS.InferenceBroker`.
Replaces the retired free-text `{"actions":[…]}` protocol entirely (FR-002, FR-015).

## Tool injection (substrate → model)

- On each inference turn, the broker resolves the run token → `{agent_name, manifest, mode,
  effective_model}` and builds the tool list from **`manifest.grants`** via each granted
  connector's registry `tool_declaration` (FR-002).
- **FR-014**: if any granted connector has `tool_declaration == nil`, the broker **raises**
  (loud failure) — generation stops before any agent body is written. (Previously a silent
  skip.)
- The model receives the tool declarations as its **only** action vocabulary. No connector,
  method, recipient, or model string is required from any LLM (FR-001).

## Gate (model tool_call → decision)

For each tool call, in order, **before any external effect**:

1. **Connector grant check** — the tool name MUST match a `manifest.grants` connector.
   Fail → typed reject `{:rejected, :ungranted_connector}` (FR-003).
2. **Method-scope check** — if the grant declares `methods`, the call's targeted method
   (an explicit `method` arg, or the connector's sole granted method) MUST be in the
   allowlist. Fail → typed reject `{:rejected, :ungranted_method}` (FR-004).
3. **Unknown connector** — not in the registry → `{:rejected, :unknown_connector}`.

Every decision (grant or reject) is **appended to the ActionTranscript** and **logged**
(FR-005, Constitution VI). A rejection does **not** abort the inference loop: the broker
returns a typed rejection tool message to the model so the agent can honour the refusal
contract.

### Rejection tool message (broker → model)

```json
{ "error": "denied", "code": "ungranted_connector" }
```

`code ∈ {ungranted_connector, ungranted_method, unknown_connector}`.

## Execution vs recording (mode)

| mode | granted call | connector cost | external effect |
|------|-------------|----------------|-----------------|
| `:live` | `execute_tool/2` runs the connector | charged | occurs |
| `:record` | **not** executed; synthetic success returned | **not** charged | **none** (FR-009) |

Synthetic success message returned to the model in `:record` mode:

```json
{ "status": "recorded" }
```

**Inference is metered against the agent's spend cap in both modes** (FR-011); only
connector-execution cost is skipped for non-executed recorded calls. Existing spend-breach
semantics are unchanged.

## Model policy

- The broker routes and prices on the registered **`effective_model`** when set, ignoring
  any `model` field supplied by the workload (FR-012). Agent-runtime tokens set it from
  `config :agent_os, :agent_runtime_model`.
- A bogus workload model claim can therefore never reach the price table (no
  `:unpriced_model` from workload strings) or select an unintended model (SC-006).

## Transcript output (broker → judge)

- The broker persists an ordered `ActionTranscript` per run token via `StateStore`
  (single writer). It is the judge's `observed_actions` input (FR-010).
- The runner **clears** the transcript for the token before invoking the agent and
  **reads** it back after exit.

## Invariants (testable)

- **INV-1**: No manifest-derived identifier (connector/method/recipient) or model
  identifier appears in any generated agent body or agent-authored prompt (SC-005).
- **INV-2**: 100% of ungranted connector/method requests are rejected **before** any
  external effect and produce a typed, recorded rejection (SC-002).
- **INV-3**: In `:record` mode, **zero** external deliveries occur across a full
  evaluation suite (SC-003).
- **INV-4**: A granted connector missing a `tool_declaration` fails generation loudly,
  writing no agent body (FR-014).
