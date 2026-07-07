# Phase 0 Research: Run-Worker Transcript Migration

No open `NEEDS CLARIFICATION` markers remained after `/speckit-specify` (the clean-cutover
decision was resolved in the spec's Assumptions). This document records the findings that
ground the plan's design decisions against the actual code on this branch.

## Finding 1 — Where effects are executed and recorded today

**Decision**: The run worker sources effects from `ActionTranscript`, not stdout.

**Rationale**: `AgentOS.CapabilityRail.evaluate_tool_calls/4`
(`lib/agent_os/capability_rail.ex`) already, during inference:
- rejects ungranted connectors / out-of-scope methods (appends `:rejected` entries),
- executes granted calls in a timeboxed isolated task and appends `:granted` entries,
- parks approval-required connectors into the `pending_approvals` store and appends
  `:parked` entries,
- returns `{:ok, tool_messages, accumulated_cost}` (or `{:breach, :spend}`).

Every outcome is written to `AgentOS.ActionTranscript` keyed by `run_token`. So the
authoritative record of "what the agent did" already exists by the time `RunWorker`
inspects the run. The worker re-deriving this from stdout is both redundant and (post-038)
broken.

**Alternatives considered**: Keep reading actions from stdout and *also* consult the
transcript — rejected: it perpetuates the double-execution hazard and the brittle stdout
contract the spec exists to retire.

## Finding 2 — Spend is already charged during inference

**Decision**: Do not re-charge approved-action cost in the run worker; read the ledger.

**Rationale**: `AgentOS.InferenceBroker` (`lib/agent_os/inference_broker.ex`, ~lines
206–255) persists both the LLM run cost and the accumulated tool cost from the rail into
the `spend_ledger` store during inference (`StateStore.apply_action("spend_ledger", …)`).
The run worker's existing post-run re-read of `spend_ledger`
(`run_worker.ex:278–281`) therefore already observes tool spend. The separate
`total_approved_cost` computation + ledger `{:put,…}` at `run_worker.ex:324–333` double-
counts once the rail executes the same actions. Removing it makes spend single-sourced.

**Alternatives considered**: Have the worker own spend accounting and the rail skip it —
rejected: spend must be enforced *during* inference (mid-run breach kills the loop), so
the rail/broker is the correct owner; the worker is a reader.

## Finding 3 — Approval parking already happens in the rail

**Decision**: Remove the worker's `pending_approvals` insertion block.

**Rationale**: The rail's parking arm (`capability_rail.ex:141–191`, landed on this
branch) writes the `%{ref, action, grant}` request into `pending_approvals` in exactly the
shape the resume path (`TriggerGateway` → `Effector.act/1`) consumes, and records a
`:parked` transcript entry. The worker's own parking loop (`run_worker.ex:335–349`) would
insert a *second* request for the same action. Reading parked entries from the transcript
for the run-log tally — without touching the store — is correct and non-duplicating.

**Alternatives considered**: Leave both and de-dup by `ref` — rejected: needless
complexity; the rail is the single writer of parks.

## Finding 4 — Clean cutover is safe

**Decision**: Treat legacy `{"actions":[…]}` stdout as malformed; do not tolerate it.

**Rationale**: Confirmed during the 038 work that no agent deployed in the wild depends on
the retired protocol (the "are we worrying about existing agents?" question was answered
"no"). The Stage-4 synthesis prompt (already landed) emits only an outcome record. A
transition window would add branching and keep the brittle path alive for zero benefit
(Constitution I). Legacy stdout lacking an `outcome` key naturally falls into the
malformed branch, which the new US1 scenario 3 asserts.

**Alternatives considered**: Dual-accept both shapes for one release — rejected: no
consumer needs it; violates Simplicity First.

## Finding 5 — Outcome record shape

**Decision**: `{"outcome": <string>, "reason": <string>}`, single line on stdout, parsed
into a typed `OutcomeRecord` struct.

**Rationale**: This is exactly what the rewritten Stage-4 prompt instructs generated
bodies to print (`lib/agent_os/pipeline/stage4_agent.ex`, landed in 038): e.g.
`print(json.dumps({"outcome": "completed", "reason": "handled via tool channel"}))` and
the refuse case `{"outcome": "refused", "reason": "out of scope"}`. The worker's parser
must accept these and reject anything lacking both keys.

**Alternatives considered**: Richer outcome schema (status enum, structured metadata) —
rejected as scope creep (Constitution II); the two-field record is what the prompt emits
and what the run log needs for legibility.

## Finding 6 — Tests must be updated, not just added

**Decision**: Update `run_supervisor_test.exs`, `port_runner_test.exs`, and the
`generation.ex` fixture to the outcome-record contract; add a dedicated transcript test.

**Rationale**: Existing tests feed stub bodies that print `{"actions": …}`
(`run_supervisor_test.exs` builds `actions_json` and asserts `actions=N`;
`port_runner_test.exs:13` asserts stdout `=~ "actions"`; the fixture's `OutputModel` has an
`actions` field). These encode the retired contract and will fail — or worse, keep passing
against a contract nothing else uses — unless migrated. A new
`run_worker_transcript_test.exs` covers US1–US4 with seeded transcripts (the path no prior
test exercised, per SC-005).

**Alternatives considered**: Add new tests and leave the old ones — rejected: leaves
green tests asserting a dead contract, and Constitution/house rule requires all tests fixed.
