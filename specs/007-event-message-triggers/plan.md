# Implementation Plan: Event-, Message-, and Approval-as-Event Triggers

**Branch**: `007-event-message-triggers` (work lands on `master` per the 002–006 convention) | **Date**: 2026-06-29 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/007-event-message-triggers/spec.md`

## Summary

Make the two already-parsed-but-inert manifest trigger types — `event {name}` and `message` — actually
fire runs, and reuse the same event mechanism to release a gate-**parked** action on a human approval.
The substrate already has every load-bearing piece except the intake and the release:

- the manifest parser already accepts `{:event, name}` and `{:message}` triggers ([manifest.ex:159-163](../../lib/agent_os/manifest.ex));
- the gate already partitions a proposed action into `{:needs_approval, grant}` → **parked**, and `RunWorker`
  already persists parked actions to a `pending_approvals` store keyed by a stable `ref_<n>`
  ([run_worker.ex:287-301](../../lib/agent_os/run_worker.ex));
- `pending_approvals` is already a single-writer `StateStore` in the supervision tree, persisted to
  `data/pending_approvals.term` ([application.ex](../../lib/agent_os/application.ex));
- `RunSupervisor.start_run/1` already takes a `trigger:` opt that flows into the run-log, and `RunWorker`
  already takes an `:items`/input opt and stamps `trigger=` provenance into the run-log
  ([run_worker.ex:182,221-226,309](../../lib/agent_os/run_worker.ex));
- `external_send` is already `requires_approval?: true` ([connector.ex:26](../../lib/agent_os/connector.ex)), so the
  discovery agent **already** produces parked actions today — nothing releases them. That is the gap.

What is missing is exactly two things, plus provenance:

1. **A substrate-side intake + dispatch point** — one new GenServer, `AgentOS.TriggerGateway`, the *only*
   trustworthy origin of an event/message/approval. It accepts an admitted signal, resolves the target
   agent(s) by reading the manifest trigger allowlist (default-deny on no match), and fires through the
   **existing** `RunSupervisor.start_run/1` path with `trigger:` provenance and the payload delivered as
   run input. The agent cannot reach the gateway's intake; untrusted web input and agent output can never
   become a signal.
2. **Approval-resume** — on an `{approve, ref}` signal the gateway reads `pending_approvals`, executes
   **exactly** that one already-gate-vetted `%{action, grant}` via `Effector.act/1` (the same post-gate
   chokepoint), removes the ref (at-most-once), and logs an `approval-resume`. On `{deny, ref}` it drops
   the ref without executing. The agent can never originate an approval.
3. **Provenance** — `event:<name>`, `message`, and `approval-resume` join `timer`/`manual` as run-log
   `trigger=` values, and `pending_approvals` becomes visible on the standing inventory.

No new trigger types, no auth framework, no change to the gate / credential proxy / spend metering.

## Technical Context

**Language/Version**: Elixir ~> 1.20 (control plane only). The Python workload changes only to read an
optional trigger-input field already delivered in its stdin JSON; no new agent logic, no model call.
**Primary Dependencies**: existing only. `RunSupervisor`, `RunWorker`, `Effector`, `Gate`, `Manifest`,
`StateStore` (`pending_approvals`), `RunLog`, `Inventory`. **No new Elixir or Python dependency.** The
gateway is a plain `GenServer` exposing function-call intake (`cast`/`call`); there is no network listener
and no new port — admitted signals enter via a substrate-side API, which is precisely what makes them
unforgeable by the agent.
**Storage**: the existing single-writer `pending_approvals` term-file (`data/pending_approvals.term`,
gitignored) and the git-backed append-only `data/run_log.md`. **No new store, no schema change** — a
pending entry already carries `%{ref, action, grant}`; this feature only *reads* and *removes* entries the
gate already writes. Trigger declarations are read from the existing manifest.
**Testing**: ExUnit, deterministic only. New `test/agent_os/trigger_gateway_test.exs` (event match fires
one run; unlisted event fires zero; message to a message-triggered agent fires, to a non-message agent is
rejected; approve-ref executes exactly that action once via an injected effector; deny-ref drops it;
unknown ref is a no-op; agent-originated approval is impossible by construction; duplicate approve is
at-most-once). New provenance cases in `test/agent_os/run_log_test.exs` / `inventory_test.exs`. The
effector and worker are injected (`effector_fn`, `worker_fn`) so no real action executes and no network/LLM
is touched (Constitution IV).
**Target Platform**: Linux/macOS host (unchanged).
**Project Type**: Single project — BEAM control plane + Python agent workload across the port boundary.
This feature is control-plane-only; the boundary is unchanged (no new egress).
**Performance Goals**: N/A — dispatch is an O(triggers) manifest scan and a map lookup; the gateway is off
any hot loop.
**Constraints**: One signal → at most one run per target agent; a parked action executes at most once
(FR-013). A held action persists across the originating run's end (FR-014). Every fire routes through the
existing supervised run path — no alternate path bypasses the gate, credential proxy, or spend metering
(FR-015). Trigger eligibility is a default-deny manifest allowlist (FR-002, FR-004). No agent self-fire or
self-approve (FR-009); signals originate only from the substrate-side intake (FR-010). The gateway is
agent-agnostic: event names and the target-agent set come from the manifest, never hard-coded in
`lib/agent_os/` (Principle IX).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Simplicity First | PASS | One new `GenServer` + an approval-resume function. Everything else is reuse: `RunSupervisor.start_run`, the existing `pending_approvals` store, the existing `trigger=` run-log field, `Effector.act/1`. No new dependency, no network listener, no new store, no schema change. Multi-tenant sender auth and approval timeouts are explicitly out of scope. |
| II. Explicit Scope Control | PASS | Exactly the spec: activate `event`/`message` triggers and release parked actions by approval. No new trigger types, no new connectors/grants, no spend changes, no v3. |
| III. Test-Driven Backend | PASS | Gateway dispatch, allowlist default-deny, approval-resume at-most-once, and provenance are backend logic — built test-first (red→green). The Python trigger-input read is a one-field integration change, not unit-tested (per III). |
| IV. No Live Dependencies in Tests | PASS | `effector_fn`/`worker_fn` are injected; signals are constructed in-test; no network listener; no LLM; no Docker. Injected `:now` where time matters. |
| V. Strong Typing, No Bare Maps | PASS | `TriggerGateway` carries `@type` for the admitted signal (`event`/`message`/`approval` variants) and `@spec` on every public function; pending entries keep their `%{ref, action, grant}` shape accessed through typed helpers. Dialyzer clean. |
| VI. Loud Failures | PASS | A rejected signal (unlisted event, non-message agent, unknown ref, unknown agent) logs a distinct line; an approval-resume logs the executed ref; a denial logs the dropped ref. No silent drop. |
| VII. Self-Documenting | PASS | Every new function gets `@doc`/`@moduledoc`; the allowlist match, the at-most-once removal, and the agent-cannot-originate boundary get intent comments. |
| VIII. Legibility | PASS, strengthened | Pending approvals become readable on the standing inventory from persisted state, and every fire is attributable from the run-log alone (`event:<name>` / `message` / `approval-resume`) — without asking the agent. |
| IX. Substrate Owns State & Lifecycle | PASS | The gateway is substrate-side and decides every fire; agents stay invocation-scoped (a trigger re-invokes them, no long-lived agent process). Agent-agnostic: event names and the target set come from the manifest, never hard-coded; no agent vocabulary enters `lib/agent_os/`. `StateStore` stays the single writer for `pending_approvals`. |
| X. No Ambient Authority | PASS | An agent cannot fire itself/another or release its own held action: signals enter only via the substrate intake the agent cannot reach, and the manifest (gate-only) remains the trigger allowlist. Approval is conferred outside any LLM. |
| XI. Deterministic Gate Is the Only Firewall | PASS | Approval-resume re-dispatches an action the gate already classified `needs_approval`; release runs through `Effector.act/1` (the post-gate chokepoint that holds the credential), with no LLM in the path. The gateway grants no new authority. |
| XII. Enforcement Precedes Generation | PASS | Pure v2 enforcement work; no v3 generation anything. |

**Result**: PASS. No violations; Complexity Tracking table omitted.

## Project Structure

### Documentation (this feature)

```text
specs/007-event-message-triggers/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 — agent resolution, signal origin/trust, input delivery, provenance, at-most-once
├── data-model.md        # Phase 1 — admitted-signal variants, pending-approval entry, provenance values
├── quickstart.md        # Phase 1 — fire an event, message the agent, approve/deny a parked external_send
├── contracts/
│   ├── trigger-gateway.md     # intake API + dispatch contract (event/message allowlist, one-signal→one-run)
│   ├── approval-resume.md     # approve/deny a ref: exactly-one, at-most-once, agent-cannot-originate
│   └── run-input-delivery.md  # event payload / message content delivered as run input + provenance
├── checklists/
│   └── requirements.md  # Spec quality checklist (from /speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
lib/agent_os/
├── trigger_gateway.ex       # NEW — the only substrate-side intake for events/messages/approvals;
│                            #        resolves target agent(s) from the manifest allowlist (default-deny),
│                            #        fires RunSupervisor.start_run with trigger provenance + input,
│                            #        and runs approval-resume (exactly-one, at-most-once) via Effector.act/1
├── application.ex           # EDIT — start AgentOS.TriggerGateway in the supervision tree
├── run_worker.ex            # EDIT (thin) — accept a :trigger_input opt and include it in the payload sent
│                            #        to the agent; accept event/message/approval trigger provenance values
├── run_log.ex               # EDIT (thin) — format trigger provenance for event:<name> / message / approval-resume
├── inventory.ex             # EDIT — render the pending_approvals store (ref + summary) on the standing inventory
├── manifest.ex              # UNCHANGED — event/message trigger shapes already parsed
├── gate.ex                  # UNCHANGED — needs_approval/parked partition reused as-is
├── effector.ex              # UNCHANGED — Effector.act/1 reused for approval-resume (post-gate chokepoint)
├── run_supervisor.ex        # UNCHANGED — start_run/1 trigger+input opts reused
└── scheduler.ex             # UNCHANGED — time-trigger path untouched

agents/discovery/
└── main.py                  # EDIT (one field) — read an optional trigger-input field from the stdin JSON
                             #        (event payload / message content); no new agent logic, no model call

test/agent_os/
├── trigger_gateway_test.exs    # NEW — event match→one run; unlisted event→zero; message allow/deny;
│                               #        approve-ref executes exactly once (injected effector); deny drops;
│                               #        unknown ref no-op; duplicate approve at-most-once
├── run_log_test.exs            # EDIT — event:<name> / message / approval-resume provenance formatting
└── inventory_test.exs          # EDIT — pending approvals shown on the standing inventory
```

**Structure Decision**: Single project, control-plane-only. One new module (`AgentOS.TriggerGateway`) added
to the existing `lib/agent_os/` supervision tree; thin edits to `run_worker.ex`, `run_log.ex`,
`inventory.ex`, `application.ex`, and a one-field read in the Python workload. No new top-level directories.

## Complexity Tracking

> No Constitution violations. Section intentionally omitted.
