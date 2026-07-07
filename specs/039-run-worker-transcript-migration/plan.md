# Implementation Plan: Run-Worker Transcript Migration

**Branch**: `039-run-worker-transcript-migration` | **Date**: 2026-07-07 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/039-run-worker-transcript-migration/spec.md`

## Summary

`RunWorker.execute_run/5` still speaks the retired `{"actions":[…]}` stdout protocol:
it decodes an action list from the agent's stdout, re-runs `Gate.partition_batch`, and
re-executes effects with `Effector.act_all` — a second gate/execute pass on top of the
one the capability rail already performed during inference. Against a 038-generated
agent (whose stdout is only an outcome record) the `%{"actions" => actions}` match fails
and the whole run is logged as malformed, dropping all accounting.

> **Scope expansion (during implementation):** the clean cutover proved unsafe for the
> deterministic *discovery* agent, which still spoke `{"actions"}` and bypassed the rail.
> The feature was expanded (user decision) to also migrate discovery onto the broker
> tool-call channel — adding `kv_append.execute_tool/2`, a discovery Python rewrite, a
> deterministic model stub, and a UDS broker test harness (`test/test_helper.exs`). See
> Phase 8 in [tasks.md](tasks.md) and FR-013/FR-014 in [spec.md](spec.md). With discovery
> migrated the cutover is genuinely clean; no compatibility window remains.

This plan migrates `RunWorker` to: (1) parse stdout as a typed **outcome record**
(`outcome` + `reason`); (2) read what the agent actually did from
`ActionTranscript.read(run_token)` (granted / parked / rejected entries the rail already
executed, parked, and recorded); (3) delete the `Gate.partition_batch` +
`Effector.act_all` + manual spend-ledger + manual parking block, since the broker/rail
already did all of that during inference; (4) derive the run-log tally and spend-breach
decision from the transcript plus the broker-maintained spend ledger. Clean cutover: the
old `{"actions"}` shape is treated as malformed, not tolerated.

## Technical Context

**Language/Version**: Elixir ~1.16 / OTP 26 (control plane); Python 3.11 only in the
sandboxed agent body fixture.
**Primary Dependencies**: Existing internal modules — `AgentOS.ActionTranscript`,
`AgentOS.CapabilityRail`, `AgentOS.InferenceBroker`, `AgentOS.RunLog`,
`AgentOS.SpendLedger`, `AgentOS.PortRunner`, `AgentOS.StateStore`, `Jason`. No new deps.
**Storage**: Single-writer term-file `StateStore` stores (`action_transcript`,
`spend_ledger`, `pending_approvals`) + git-backed markdown run log. No external DB.
**Testing**: ExUnit. Drive via `PortRunner`/agent-cmd stubs printing an outcome record to
stdout + pre-seeded `ActionTranscript`/`spend_ledger`/`pending_approvals` fixtures. No
live model calls (Constitution IV).
**Target Platform**: Local BEAM node (prototype).
**Project Type**: Single Elixir/OTP project (control plane) with Python port workloads.
**Performance Goals**: N/A — correctness/legibility change, not perf-sensitive.
**Constraints**: Transcript stays single-writer keyed by run token; `RunWorker` is a
reader only. Strongly-typed structs across the outcome-record and transcript boundaries.
No second execution of any effect.
**Scale/Scope**: One module rewritten (`run_worker.ex` `execute_run/5` + a new outcome
parser), one fixture updated, three test files updated/added. Estimated ~1 module of net
change plus test churn.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Simplicity First** — PASS. Net effect is *deletion*: the second gate/execute/spend
  block goes away, replaced by a transcript read + tally. No new abstraction.
- **II. Explicit Scope Control** — PASS. Scope is exactly the run_worker read path and its
  tests. Rail gating/execution and the Stage-4 prompt are explicitly out of scope.
- **III. Test-Driven Backend** — PASS. This is backend logic; RED tests (US1–US4) written
  first against seeded transcripts, then the migration turns them green.
- **IV. No Live Dependencies in Tests** — PASS (load-bearing). Every test uses stdout
  stubs + seeded stores; no LLM call. This is the whole reason the defect went uncaught,
  and the new US1 test closes that gap (SC-005).
- **V. Strong Typing, No Bare Maps** — PASS. A typed `OutcomeRecord` struct replaces the
  ad-hoc `%{"actions" => …}` map match; transcript `Entry` structs are already typed. No
  new bare-map contracts.
- **VI. Loud Failures** — PASS. Malformed stdout and breach paths log with context
  (agent, run token, reason) as the existing code does.
- **VII. Self-Documenting** — PASS. New/changed functions carry `@doc`/`@spec`; the
  "why" (rail already executed; worker is a reader) is commented at the deletion site.
- **VIII. Legibility** — PASS/positive. Restores correct run-log traces for real agents
  that are currently logged as malformed — a legibility *fix*.
- **IX. Substrate Owns State & Lifecycle** — PASS. Transcript remains single-writer keyed
  by run token; worker only reads it. No agent-domain vocabulary enters `lib/agent_os/`.
- **X. No Ambient Authority** — PASS/positive. Removing the worker's second
  `Effector.act_all` means execution happens only through the rail's gate — narrowing,
  never widening, authority.
- **XI. Deterministic Gate Is the Only Firewall** — PASS. Effects cross the gate exactly
  once (in the rail). The worker holds no credential and performs no privileged action.
- **XII. Enforcement Precedes Generation** — PASS. This hardens enforcement plumbing on
  the already-landed rail; ordering unaffected.

**Result: no violations. Complexity Tracking not required.**

## Project Structure

### Documentation (this feature)

```text
specs/039-run-worker-transcript-migration/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── outcome-record.md   # stdout contract: agent → run worker
├── checklists/
│   └── requirements.md  # from /speckit-specify
└── tasks.md             # /speckit-tasks output (NOT created here)
```

### Source Code (repository root)

```text
lib/agent_os/
├── run_worker.ex            # PRIMARY CHANGE: execute_run/5 rewrite; new outcome parser
├── action_transcript.ex     # READ-ONLY consumer (add read helpers if needed for tally)
├── capability_rail.ex       # unchanged (already executes/parks/records)
├── inference_broker.ex       # unchanged (already persists tool spend to ledger)
├── run_log.ex               # unchanged (same append contract)
└── spend_ledger.ex          # unchanged (window/entry helpers reused)

test/
├── agent_os/
│   ├── outcome_record_test.exs          # NEW: parse/1 accept/reject contract (FR-012) — non-string outcome, missing key, empty stdout, legacy actions
│   ├── run_worker_transcript_test.exs   # NEW: US1–US4 against seeded transcripts; also asserts malformed stdout leaves a populated transcript intact (FR-008 edge) and the worker never mutates the transcript (FR-011, single-writer reader invariant)
│   ├── run_supervisor_test.exs          # UPDATE: retire {"actions"} stubs → outcome record
│   └── port_runner_test.exs             # UPDATE: assert outcome-record stdout, not "actions"
└── fixtures/generation/generation.ex    # UPDATE: stub body prints outcome record; models.py outcome-only
```

**Structure Decision**: Single Elixir/OTP project. The change is localized to
`run_worker.ex` and its tests/fixture; every collaborator it now reads from
(`ActionTranscript`, `SpendLedger`, `spend_ledger`/`pending_approvals` stores) already
exists and is unchanged by this feature.

## Key Design Decisions

1. **`OutcomeRecord` typed struct** with `outcome :: String.t()` and `reason ::
   String.t()`, plus `OutcomeRecord.parse/1` returning `{:ok, %OutcomeRecord{}} |
   {:error, :malformed}`. Replaces the inline `%{"actions" => actions}` match. Legacy
   `{"actions": …}` stdout has no `outcome` key → `{:error, :malformed}` (clean cutover).

2. **Effect tally from the transcript.** After a successful run, read
   `ActionTranscript.read(run_token)` and count entries by `kind`:
   `granted → approved_count`, `parked → parked_count`, `rejected → rejected_count`;
   `gate_reasons` = unique `reason_code`s of rejected entries. This replaces the
   `Gate.partition_batch` return tuple.

3. **Delete the second gate/execute/spend/park block.** `Gate.partition_batch`,
   `Effector.act_all`, the manual `spend_ledger` `{:put,…}` for approved cost, and the
   manual `pending_approvals` insertion are all removed from `execute_run/5` — the rail
   already executed granted calls, charged the ledger (broker persists tool cost), and
   parked approval-required calls during inference.

4. **Spend & breach from the ledger.** Keep the pre-check and the post-run re-read of
   `spend_ledger` (broker updates it during inference). If `spent >= cap` after the run,
   dispatch on breach exactly as today — but the counts fed to `dispatch_on_breach` now
   come from the transcript, not from a decoded action list.

5. **Malformed-outcome run.** If `OutcomeRecord.parse/1` fails, log a `:error` run with
   `failure_cause: "malformed_outcome"` and a note naming the retired protocol. Effects
   already recorded in the transcript are left intact (not undone) — the transcript is the
   record of what happened.

6. **`dispatch_on_breach` signature.** Update its callers to pass transcript-derived
   counts; the function body's shape (RunLog fields) is preserved so RunLog stays stable.

## Complexity Tracking

No Constitution violations. Table intentionally omitted.
