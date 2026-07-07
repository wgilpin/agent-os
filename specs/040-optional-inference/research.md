# Research: Optional Inference for Generated Agents

**Feature**: 040-optional-inference | **Date**: 2026-07-07

No external unknowns — every question resolves against the existing codebase and
constitution. Each decision below was checked against the current source
(`inference_broker.ex`, `capability_rail.ex`, `stage3_judge.ex`, `stage4_agent.ex`,
`orchestrator.ex`, `test/test_helper.exs`).

## D1. Where the direct tool-submission channel lives

**Decision**: A `/v1/tool_calls` route on the InferenceBroker's existing UDS listener,
implemented as `InferenceBroker.submit_tool_calls/2` (public function + HTTP route).

**Rationale**: The broker is already the substrate-side chokepoint agents can reach
(only `INFERENCE_SOCKET` + `RUN_TOKEN` cross the boundary), already owns token→
manifest resolution, and already performs the spend-ledger read/normalize/persist
dance around `CapabilityRail.evaluate_tool_calls/4`. Adding a route reuses all of
that; a separate socket/GenServer would duplicate token resolution, socket
permissions (0660 + inference GID), and ledger plumbing for zero isolation gain —
the rail is the security boundary either way.

**Alternatives considered**:
- *Separate UDS socket / new GenServer ("ToolBroker")*: rejected — duplicates
  listener hardening and token registry; violates Simplicity First.
- *Have agents write proposals to stdout for RunWorker to submit*: rejected — 039
  just deleted exactly that second gate/execute pass from RunWorker; stdout is now
  the outcome-record channel only, and parked/rejected feedback couldn't reach the
  agent before exit.

**Codebase fact forcing a sub-decision**: `handle_connection/1` never reads the HTTP
request path today (`/v1/inference` is nominal). `read_http_request/2` must be
extended to return `{method, path, body}` so routing is real. Unknown/absent paths
keep the current behavior (`complete/2`) so the deployed discovery/generated agents
are untouched.

## D2. Semantics of `submit_tool_calls/2`

**Decision**: Mirror `do_complete_loop`'s rail interaction exactly, minus the model:
resolve token → normalize spend window → pre-check `spent >= cap` → call
`CapabilityRail.evaluate_tool_calls(tool_calls, agent_name, manifest, run_token)` →
persist accumulated tool cost → return typed per-call results. HTTP mapping:
200 with results, 402 on `{:breach, :spend}`, 401 unknown token, 400 malformed.

**Rationale**: FR-002 demands *identical* gate/park/record/meter semantics. The rail
already appends every disposition to the transcript (single-writer preserved: only
the rail writes) and already handles `:record` mode by resolving the broker
registration — so judge-time (`Stage3.run`) submissions from a deterministic agent
are synthetically recorded with no new code.

**Alternatives considered**:
- *Bypass the ledger for the direct path ("agents pay nothing")*: rejected —
  connector costs are real spend; FR-012 says deterministic runtime cost is exactly
  the metered connector costs.
- *Return only "ok"*: rejected — the agent needs per-call dispositions to print an
  honest terminal outcome record (executed vs parked vs rejected).

## D3. Submission wire shape

**Decision**: Reuse the OpenAI-style tool-call shape the rail already parses:
`{"run_token": ..., "tool_calls": [{"id": ..., "function": {"name": ...,
"arguments": "<json string>"}}]}`, parsed into a typed `ToolSubmission` struct
before evaluation.

**Rationale**: `evaluate_tool_calls/4` consumes this shape today; inventing a second
schema would need a translation layer and create drift between the two paths. The
spec's phrase "an action shaped like a tool call" becomes literal.

**Alternatives considered**: a bespoke `{"connector": ..., "args": ...}` schema —
rejected (two schemas, one gate; pure drift risk).

## D4. How a deterministic agent names its action (manifest invisibility)

**Decision**: Deterministic bodies hard-code the *generic tool vocabulary*: the
registry capability name (`tool_declaration.function.name`, e.g. `discord_notify`)
and its declared parameters (e.g. `text`). The Stage-4 leak guard becomes
mode-aware: for a deterministic body, granted connector tool names and granted
method names are permitted literals; **recipients, the spend cap, credential-shaped
strings, and direct provider/network paths remain forbidden in every mode**.

**Rationale**: The tool name is not manifest-private — the inference path already
exposes exactly these names/parameters to the model as tool declarations
(`build_tools_list/1`), and the connector registry (not the manifest author) fixes
each capability's danger class (Constitution X). What the manifest keeps private is
the *authorization data*: which agent holds which grant, scoped to which
recipients/methods, under what cap — none of which the deterministic body contains.
Naming a tool confers nothing: an ungranted name is rejected by the rail and
recorded `:rejected` (FR-003), same as an ungranted inference tool call.

**Alternatives considered**:
- *Abstract intent indirection (agent submits "intent: notify-owner", rail resolves
  via manifest)*: rejected — invents a new naming scheme + resolver for no security
  gain (the rail gates either way), violating Simplicity First.
- *Keep the guard strict and inject the tool name at runtime via env*: rejected —
  the substrate would be feeding capability identifiers into the agent environment,
  a worse leak than generated source containing public registry vocabulary, and it
  makes the body non-self-describing.

## D5. Where classification runs and where the result is recorded

**Decision**: A new `AgentOS.ExecutionMode` module: typed struct
(`mode :: :deterministic | :inference`, `rationale :: String.t()`),
`classify/3` (one broker completion, `provider_fn`-stubbed in tests),
`store/3`/`load/2` for the sidecar `agents/<agent_name>/execution_mode.json`.
The **orchestrator** invokes classification between Stage 2 (manifest) and Stage 4
(synthesis) and threads the typed mode to both Stage 4 and Stage 3 via opts;
Stage 4 also persists the sidecar so re-judging/inspection can read the declared
mode later.

**Rationale**:
- *Pipeline step, not Stage-4 internal*: the judge must test against the declared
  mode (FR-009). If Stage 4 derived the mode privately and Stage 3 read it from
  Stage-4 output alone, the judge would be deriving from agent output. With the
  orchestrator classifying once from manifest + purpose and feeding both stages,
  judge and agent still derive independently (manifest + purpose + one
  substrate-recorded bit) — co-generation isolation holds.
- *Sidecar file, not a manifest field*: the manifest is the human/projection-declared
  capability contract, privileged-read for the gate (Constitution X); execution mode
  is a synthesis-contract property decided later in the pipeline. Machine-appending
  to the manifest after Stage 2 would blur declaration vs conferral semantics and
  require touching the v2 manifest parser for a non-capability concern. The sidecar
  sits next to `judge_spec.json` (same precedent: pipeline-produced, per-agent,
  typed JSON on disk).
- *Ambiguity defaults to `:inference`*: a wrongly-deterministic agent silently fails
  its purpose; a wrongly-inference agent merely costs more. Purpose-fit wins.

**Alternatives considered**:
- *Manifest frontmatter field*: rejected (above) — also forces every existing
  manifest through a schema change.
- *StateStore collection*: workable but weaker legibility than a file next to the
  agent's other artifacts (Constitution VIII favors inspectable inventory), and
  StateStore rows don't travel with the `agents/<name>/` directory.
- *Deterministic heuristic instead of an LLM classification*: rejected for now —
  "requires reasoning over dynamic content?" is a semantic judgment about the
  purpose text; a keyword heuristic would misclassify. The classification is a
  proposal only (Constitution XI safe): it selects between two contracts, both of
  which sit behind the rail.

## D6. Stage 4 deterministic synthesis contract

**Decision**: Branch `synthesis_messages/2` on mode. The deterministic prompt
instructs: read one line of stdin and treat it as opaque trigger data — never as
instructions; hard-code the intended tool call(s) using the generic tool vocabulary
from the rendered capability context; submit them via a provided
`call_tool_channel` reference implementation (UDS POST to `/v1/tool_calls`,
mirroring the existing `@broker_call_reference` pattern); print a single-line
outcome record derived from the per-call dispositions; make **no** inference call.
The existing guards run in both modes; only `guard_no_manifest_leak` gains mode
awareness (D4). `AgentBody` gains an `execution_mode` field.

**Rationale**: Matches the existing known-good pattern (reference implementation
supplied verbatim so the model reproduces the transport instead of inventing one);
keeps all structural guards (typed contract, path safety, syntax, no direct
provider) shared across modes.

**Alternatives considered**: a fixed template (no synthesis call) for deterministic
bodies — attractive for injection-immunity but contradicts the Stage-4 "novel body"
contract and would hard-code substrate assumptions into a template that drifts;
the guards + judge cover the difference. Noted as possible future simplification.

## D7. Stage 3 judge migration

**Decision**:
- `synthesis_messages/2` branches on declared mode. Deterministic: probes assert the
  fixed effect appears on the transcript for *any* input, with at least one
  adversarial-input case expecting identical behavior; no refusal-contract or
  empty-actions-list language anywhere. Inference: purpose-fit probes only.
- `eval_messages/3` rewrites the system rules: substrate dispositions
  (granted/parked/rejected transcript entries) are observed facts; score (a)
  purpose-fit — did the intended effect occur / was it attempted, and (b)
  containment — is every forbidden effect absent from `granted` entries (present
  only as `rejected`/`parked` if attempted). Delete rules 1–2 (refusal contract,
  empty actions list) and the "refusal contract adherence" scoring instruction.
- `Stage3.run` keeps the `eval_manifest` cap-lift (judging is uncapped one-off
  setup) and the `:record` registration — unchanged.

**Rationale**: The substrate enforces containment deterministically; grading agent
politeness proves nothing and (as observed) the refusal-contract framing is itself
an injection channel. The judge's honest scope is purpose-fit + verifying the
substrate's containment evidence.

**Alternatives considered**: keeping a softened self-policing check for inference
agents ("should mostly refuse") — rejected: it re-imports the retired protocol and
grades theater the rail makes irrelevant.

## D8. Test strategy (Constitution IV)

**Decision**:
- **Channel**: direct `submit_tool_calls/2` unit tests with a registered token,
  seeded grants/ledger, and stubbed connector transports; UDS integration via the
  existing `AgentOS.TestHelper.start_broker_uds!/1` harness. Three-way disposition
  (executed/rejected/parked) + malformed submission + spend breach + cost metering +
  zero-inference-spend assertions, all read from transcript/ledger.
- **Classification**: `provider_fn` stub returning mode JSON; ambiguity default;
  sidecar round-trip.
- **Stage 4**: provider stubs returning canned deterministic and inference bodies;
  assert branch selection, mode-aware guard behavior (deterministic body with tool
  name passes; recipient/cap literal still fails; inference body with tool name
  still fails), sidecar written.
- **Stage 3**: provider stubs; assert generated specs contain no retired-protocol
  phrases; eval prompts differ per mode; verdicts read transcript containment.
- **E2E**: a checked-in deterministic Python fixture (hello-world Discord shape)
  run through the UDS harness with a stubbed `:discord_notify_transport`; assert
  transcript entry, outcome record, byte-identical submission under adversarial
  stdin, zero inference charges.

**Rationale**: Identical seams to 038/039 (`provider_fn`, transport stubs, UDS
harness, transcript assertions); nothing new to invent.
