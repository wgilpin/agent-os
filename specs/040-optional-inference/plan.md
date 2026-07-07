# Implementation Plan: Optional Inference for Generated Agents

**Branch**: `040-optional-inference` | **Date**: 2026-07-07 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/040-optional-inference/spec.md`

## Summary

Feature 038 made LLM inference mandatory for every generated agent: the only way to
reach `CapabilityRail.evaluate_tool_calls/4` (the gate→execute→park→record→charge
primitive) is through `InferenceBroker.complete/2`'s model loop. This feature:

1. Adds a **direct tool-submission channel** — a `/v1/tool_calls` route on the
   broker's existing UDS that runs submitted tool calls through the rail with **no
   model call**, with identical gating/parking/recording/metering semantics. (The
   current UDS handler ignores the HTTP request path entirely; routing must be added.)
2. Makes the deterministic/inference choice an **explicit typed classification**
   (`ExecutionMode`) performed once per purpose before synthesis, recorded to a
   sidecar (`agents/<name>/execution_mode.json`), and threaded to both Stage 4
   (synthesis contract branch) and Stage 3 (mode-aware judge).
3. Adds a **deterministic synthesis contract** to Stage 4: `main.py` hard-codes its
   tool call(s) in the generic tool-declaration vocabulary, submits them to
   `/v1/tool_calls`, treats stdin as opaque data (never instructions), and prints an
   outcome record. The Stage-4 leak guard becomes mode-aware to permit granted tool
   names in deterministic bodies (they are registry vocabulary, not manifest secrets).
4. **Migrates the Stage 3 judge off the retired protocol**: no "empty actions list"
   expectations, no agent self-policing checks; the judge verifies purpose-fit and
   substrate containment (read from the ActionTranscript) against the declared mode.

## Technical Context

**Language/Version**: Elixir ~1.16 / OTP 26 (control plane); Python 3.11 for the
sandboxed generated-agent bodies and test fixtures.
**Primary Dependencies**: Existing internal modules only — `AgentOS.InferenceBroker`,
`AgentOS.CapabilityRail`, `AgentOS.ActionTranscript`, `AgentOS.SpendLedger`,
`AgentOS.Pipeline.Stage3`/`Stage4`/`Orchestrator`, `AgentOS.Connector` registry,
`Jason`. No new external deps.
**Storage**: Single-writer term-file `StateStore` (`action_transcript`,
`spend_ledger`, `pending_approvals`, `judge_results`) + `agents/<name>/` files
(new `execution_mode.json` sidecar). No external DB.
**Testing**: ExUnit. Broker channel driven directly and over UDS via the existing
`AgentOS.TestHelper.start_broker_uds!/1` harness; classification and both synthesis
contracts driven via `provider_fn` stubs; connector effects via transport stubs
(e.g. `:discord_notify_transport`); assertions read the ActionTranscript. No live
model calls (Constitution IV).
**Target Platform**: Local BEAM node (prototype).
**Project Type**: Single Elixir/OTP project with Python port workloads.
**Performance Goals**: N/A — correctness/safety feature. (Deterministic agents drop
model-call latency/cost as a side effect, not a tuned target.)
**Constraints**: Rail remains the sole firewall (every submission gated); transcript
single-writer keyed by run token; typed structs at every new boundary (submission
request, channel response, execution mode); runtime spend caps unchanged, judging
stays uncapped (`Stage3.run`'s `eval_manifest` cap-lift is preserved).
**Scale/Scope**: ~1 new module (`ExecutionMode`), surgical changes to 4 existing
modules (`inference_broker.ex`, `stage4_agent.ex`, `stage3_judge.ex`,
`orchestrator.ex`), 1 new deterministic Python fixture, ~5 test files new/updated.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Simplicity First** — PASS. The channel is a thin route to an existing
  primitive (`evaluate_tool_calls/4`), not a new enforcement path. `ExecutionMode`
  is one small struct + two-value atom. The deterministic contract *removes* a
  moving part (the model loop) from fixed-action agents.
- **II. Explicit Scope Control** — PASS. Scope matches the spec exactly; discovery's
  deterministic rewrite is explicitly deferred as a follow-up; trigger-data
  templating into deterministic arguments is explicitly out of scope.
- **III. Test-Driven Backend** — PASS. RED tests first for the channel (three-way
  disposition), classification branch, guard mode-awareness, and judge migration;
  then implementation turns them green.
- **IV. No Live Dependencies in Tests** — PASS (load-bearing). Classification and
  synthesis via `provider_fn` stubs; channel via pre-seeded grants/ledger + UDS
  harness; connector effects via transport stubs; assertions via transcript.
- **V. Strong Typing, No Bare Maps** — PASS. New typed structs: `ExecutionMode`,
  `ToolSubmission` (+ per-call result). Python fixture bodies keep Pydantic models.
  The mode is a typed value (`:deterministic | :inference`), not a bare string.
- **VI. Loud Failures** — PASS. Malformed submissions, unknown tokens, and guard
  failures all log with agent/run-token context and return recorded errors; nothing
  is silently dropped (malformed calls are recorded `:rejected`).
- **VII. Self-Documenting** — PASS. New functions carry `@doc`/`@spec`; the
  manifest-invisibility decision (why tool names are permitted in deterministic
  bodies) is documented at the guard site.
- **VIII. Legibility** — PASS/positive. Deterministic runs produce the same
  transcript trace as inference runs; the recorded `ExecutionMode` adds standing
  inventory ("what kind of agent is this") readable without asking the agent.
- **IX. Substrate Owns State & Lifecycle** — PASS. Transcript stays single-writer
  (only the rail appends); the channel adds no new store; no agent-domain vocabulary
  enters `lib/agent_os/` (mode names are substrate-generic).
- **X. No Ambient Authority** — PASS/positive. The submission channel confers
  nothing: naming a tool grants nothing; the rail resolves every call against the
  privileged-read manifest. Classification proposes a *narrowing* (no-LLM) contract,
  never a grant. The agent still never reads the manifest.
- **XI. Deterministic Gate Is the Only Firewall** — PASS/positive (the point of the
  feature). The no-LLM agent is the purest expression of this principle: it proposes,
  the rail disposes. Every direct submission crosses the same gate as inference tool
  calls; an ungranted submission is rejected and recorded identically.
- **XII. Enforcement Precedes Generation** — PASS. The enforcement primitive (rail)
  is already landed and unchanged in semantics; generation (Stage 4) merely gains a
  second contract that targets it.

**Result: no violations. Complexity Tracking not required.**

## Project Structure

### Documentation (this feature)

```text
specs/040-optional-inference/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── tool-calls-channel.md        # UDS /v1/tool_calls request/response contract
│   ├── execution-mode.md            # classification + sidecar file contract
│   └── deterministic-agent.md       # deterministic body stdin/stdout/submission contract
├── checklists/
│   └── requirements.md  # from /speckit-specify
└── tasks.md             # /speckit-tasks output (NOT created here)
```

### Source Code (repository root)

```text
lib/agent_os/
├── inference_broker.ex        # CHANGE: parse request path in UDS handler; route
│                              #   /v1/tool_calls → new submit_tool_calls/2 (resolve
│                              #   token → rail → persist tool cost → typed response);
│                              #   default route stays complete/2 (back-compat)
├── tool_submission.ex         # NEW: typed submission request + per-call result structs
├── execution_mode.ex          # NEW: typed mode (:deterministic | :inference) +
│                              #   classify/3 (broker call, stubbed in tests) +
│                              #   store/load of agents/<name>/execution_mode.json
├── capability_rail.ex         # UNCHANGED (already the reusable gate primitive;
│                              #   :record mode already covers judge-time submissions)
└── pipeline/
    ├── stage4_agent.ex        # CHANGE: accept ExecutionMode; branch to deterministic
    │                          #   vs inference synthesis prompt; mode-aware
    │                          #   guard_no_manifest_leak (tool names allowed in
    │                          #   deterministic bodies; recipients/cap/credentials
    │                          #   still forbidden); write sidecar; AgentBody gains
    │                          #   execution_mode
    ├── stage3_judge.ex        # CHANGE: mode-aware synthesis prompt (drop refusal-
    │                          #   contract / empty-actions-list rules); eval prompt
    │                          #   scores purpose-fit + transcript containment; keep
    │                          #   eval_manifest cap-lift and :record registration
    └── orchestrator.ex        # CHANGE: classification step between Stage 2 and
                               #   Stage 4; thread mode to Stage 4 and Stage 3

test/
├── agent_os/
│   ├── tool_channel_test.exs              # NEW: submit_tool_calls/2 three-way
│   │                                      #   disposition (executed/rejected/parked),
│   │                                      #   malformed submission, cost metering,
│   │                                      #   spend breach, UDS routing via
│   │                                      #   start_broker_uds!/1, zero inference spend
│   ├── execution_mode_test.exs            # NEW: classify via provider_fn stub,
│   │                                      #   ambiguity→inference default, sidecar
│   │                                      #   store/load round-trip, typed parse errors
│   └── pipeline/
│       ├── stage4_agent_test.exs          # UPDATE: contract branch per mode;
│       │                                  #   deterministic leak-guard allowances;
│       │                                  #   inference guard unchanged
│       ├── stage3_judge_test.exs          # UPDATE: no retired-protocol expectations
│       │                                  #   in generated specs; mode-aware prompts;
│       │                                  #   containment asserted from transcript
│       └── orchestrator_test.exs          # UPDATE: classification threaded end-to-end
├── fixtures/generation/                   # UPDATE: deterministic stub body fixture
└── e2e (in tool_channel or a dedicated file): deterministic hello-world fixture run
    end-to-end (UDS broker + stubbed connector transport) asserting transcript,
    outcome record, injection-immunity (adversarial stdin → byte-identical submission),
    and zero inference charges
```

**Structure Decision**: Single Elixir/OTP project. The rail is untouched; the broker
gains a route to it; the pipeline gains a classification step and a second synthesis
contract; the judge prompt/eval migrate. The deterministic Python body exists only as
generated output and test fixtures — no new deployed Python source in this feature.

## Key Design Decisions

(Full rationale and alternatives in [research.md](research.md).)

1. **Channel = new route on the existing UDS, handled by the broker.** The current
   `handle_connection` ignores the request line; `read_http_request` will also return
   the request path, and the handler routes `/v1/tool_calls` to
   `InferenceBroker.submit_tool_calls/2`. Everything else keeps today's behavior
   (`complete/2`), so deployed agents posting `/v1/inference` are untouched.

2. **`submit_tool_calls/2` mirrors the inference path's rail interaction exactly**:
   resolve token → spend-window normalization → pre-check cap →
   `CapabilityRail.evaluate_tool_calls(tool_calls, agent_name, manifest, run_token)`
   → persist accumulated tool cost to `spend_ledger` → typed response. The rail
   appends every disposition to the transcript (single writer preserved). `:record`
   mode (used by `Stage3.run`) already short-circuits execution inside the rail, so
   judge-time deterministic submissions need zero new code.

3. **Submissions use the same OpenAI-style tool-call shape the rail already parses**
   (`{"id", "function": {"name", "arguments": <json-string>}}`). No second schema; a
   deterministic agent "proposes an action shaped like a tool call" literally.

4. **Manifest invisibility resolution**: the generic tool name (registry capability
   name, e.g. what the tool declaration exposes) and the tool-declaration argument
   vocabulary are *not* manifest-private — the inference path already shows them to
   the model. Deterministic bodies may therefore hard-code them. What stays
   forbidden in generated code, in every mode: recipients, spend cap, credentials,
   direct provider/network paths. `guard_no_manifest_leak/2` becomes
   `guard_no_manifest_leak/3` (mode-aware).

5. **Classification is a pipeline step, not a Stage-4 internal**: the orchestrator
   calls `ExecutionMode.classify(agent_name, manifest, opts)` (one broker completion;
   `provider_fn`-stubbed in tests) between Stage 2 and Stage 4, persists the sidecar,
   and threads the typed mode to both Stage 4 and Stage 3. Both stages derive from
   manifest + purpose + mode; neither derives from the other — co-generation
   isolation is preserved (the judge still never sees agent code; it sees one
   substrate-recorded bit plus rationale). Ambiguity defaults to `:inference`
   (wrongly-deterministic breaks purpose-fit; wrongly-inference only costs more).

6. **Judge migration**: Stage 3's synthesis prompt branches on mode. Deterministic:
   expected behavior is "the fixed effect appears on the transcript for any input,
   including adversarial input"; no refusal-contract language. Inference: purpose-fit
   probes only. Both: containment is asserted from transcript facts (`:rejected` /
   `:parked` entries), never from agent self-reports; the "empty actions list" and
   self-policing rules are deleted from both the synthesis prompt and
   `eval_messages/3`. The `eval_manifest` cap-lift and `:record` registration in
   `Stage3.run` are preserved verbatim (do not regress the 038-era fix).

7. **Working-tree note**: the modified
   `agents/send_a_hello_world_.../judge_spec.json` + manifest on this branch are the
   observed-injection artifacts motivating this feature; regenerating that agent
   deterministically is the validation quickstart, not a source change in this plan.

## Complexity Tracking

No Constitution violations. Table intentionally omitted.
