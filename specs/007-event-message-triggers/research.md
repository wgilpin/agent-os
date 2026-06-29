# Phase 0 Research: Event-, Message-, and Approval-as-Event Triggers

All open decisions below were resolvable from the existing codebase and constitution; no NEEDS
CLARIFICATION remained after the spec. Each entry records the decision, the rationale, and the
alternatives rejected.

## R1 — Where do admitted signals originate (the trust boundary)?

**Decision**: A new substrate-side `GenServer`, `AgentOS.TriggerGateway`, is the single intake. Admitted
signals enter through its Elixir function API (`cast`/`call`) from inside the control plane only. There is
**no network listener and no new port**.

**Rationale**: The agent runs sandboxed across the port boundary with `network: none`; it can only write
its stdout actions (gate-checked) and read its stdin input. It has no channel into a substrate `GenServer`.
Making the intake a substrate-internal API means an event/message/approval is, by construction,
*un-spoofable* by untrusted web input or agent output (FR-010, Principle X) — there is no surface the agent
can reach. The operator-via-chat and any future external feed are themselves substrate-side processes that
call this API (the "you are another process" property), so they are not a privileged shortcut but the same
single door (FR-005).

**Alternatives rejected**:
- *HTTP/UDS listener now* — adds a transport, a parser, and an auth story for a single-operator prototype;
  violates Principle I and pulls in 03-06/multi-tenant concerns the spec puts out of scope.
- *Let the agent emit a "fire" action* — would let an LLM-running component confer a trigger on itself or
  another agent; a direct Principle X / FR-009 violation.

## R2 — How is the target agent resolved, agent-agnostically?

**Decision**: For an **event**, the gateway scans the loaded manifest(s) and fires every agent whose
manifest declares an `event` trigger whose `name` equals the admitted event name (default-deny on no
match). For a **message**, the signal carries the target agent name and fires only if that agent's manifest
declares a `message` trigger. Event names and the target set come entirely from manifest data.

**Rationale**: This keeps the gateway agent-agnostic (Principle IX) — no event name or agent identity is
hard-coded in `lib/agent_os/`. It mirrors the gate's own allowlist posture: the manifest is the source of
truth and absence ⇒ deny (FR-002, FR-004). The current prototype has one manifest (discovery), so "scan
all manifests" is trivially "check the one"; the shape generalises without rework when more agents exist.

**Alternatives rejected**:
- *Hard-code the discovery agent as the event target* — a domain leak into the kernel (Principle IX
  violation) and untestable as an allowlist.
- *Events addressed to a specific agent like messages* — the spec models events as a named signal matched
  by manifest, distinct from a message addressed to one agent; keeping them distinct preserves the
  "broadcast to whoever declared it" semantics without extra config.

## R3 — How is the payload/message delivered to the run as input?

**Decision**: The gateway passes the event payload / message content to `RunSupervisor.start_run/1` as a
new `:trigger_input` opt. `RunWorker` includes it as a field in the JSON payload it already builds and
feeds to the agent over stdin ([run_worker.ex:221-226](../../lib/agent_os/run_worker.ex)). The Python
workload reads that optional field. When absent (e.g. a timer fire), behaviour is exactly as today.

**Rationale**: Input already flows substrate → agent as a single stdin JSON line built by
`build_payload/2`; adding one optional field is the smallest change that delivers the payload as the run's
hand-input (FR-001, FR-003) without touching the port protocol or the gate. The field is plain data the
agent treats as untrusted input — consistent with how it already treats sanitized bookmarks.

**Alternatives rejected**:
- *A second stdin line / new port message* — changes the one-line port protocol the stdin-guard wrapper
  depends on; unjustified complexity (Principle I).
- *Write the payload to a mounted file* — adds a store and a cleanup story for transient per-run input.

## R4 — Approval-resume: exactly-one and at-most-once

**Decision**: An approval signal is `{:approve | :deny, ref}`. On `:approve`, the gateway reads
`pending_approvals`, looks up `ref`, and — if present — **removes it first**, then executes that single
`%{action, grant}` via `Effector.act/1`. On `:deny`, it removes `ref` without executing. An unknown `ref`
is a logged no-op. Removal-before-execute (single-writer `StateStore`) guarantees a duplicate `:approve`
for the same `ref` finds nothing and executes zero further times (FR-013, at-most-once).

**Rationale**: The parked entry already stores exactly `%{ref, action, grant}`
([run_worker.ex:294](../../lib/agent_os/run_worker.ex)) and `Effector.act/1` already consumes exactly that
shape ([effector.ex:20-22](../../lib/agent_os/effector.ex)) — the action was already classified
`needs_approval` by the gate, so resume re-dispatches an *already-vetted* action through the post-gate
chokepoint with no LLM in the path (FR-007, Principle XI). The `StateStore` single writer makes
remove-then-act race-free without locks.

**Alternatives rejected**:
- *Execute then remove* — a crash between act and remove could re-execute on a retried approval; ordering
  removal first makes the at-most-once guarantee structural.
- *Re-run the gate on resume* — redundant; the gate already produced the `needs_approval` verdict, and the
  action/grant are stored. Re-running risks a different verdict if registry/manifest drifted mid-wait,
  which is a 03-06 concern, not this slice.

## R5 — Can an agent originate an approval?

**Decision**: No — structurally. Approvals enter only through `TriggerGateway`'s substrate-side API (R1).
The agent's only output is its stdout action batch, which the gate routes to `approved`/`parked`/
`rejected`/`breached` — there is no action type that releases a parked ref, and the gateway never reads
agent output as an approval source.

**Rationale**: Satisfies FR-009 and US3 scenario 5 (agent self-approve must fail) by construction rather
than by a runtime check that could be bypassed.

**Alternatives rejected**:
- *An "approve" action type gated by manifest* — would make approval an agent-emittable capability,
  collapsing the human-in-the-loop boundary the feature exists to prove.

## R6 — Provenance values and one-signal-one-run

**Decision**: Run-log `trigger=` gains `event:<name>`, `message`, and `approval-resume` alongside the
existing `timer`/`manual`. The gateway issues exactly one `start_run` per admitted event per matching
agent and per admitted message; approval-resume logs a distinct line (it executes an action without
starting a new agent run). `pending_approvals` is rendered on the inventory (ref + a short action summary).

**Rationale**: `RunWorker` already stamps `trigger=` and `RunLog` already parses it
([run_log.ex:45](../../lib/agent_os/run_log.ex), [inventory.ex:106-115](../../lib/agent_os/inventory.ex));
extending the value set keeps every fire attributable from the log alone (Principle VIII, FR-011). One
`start_run` per signal gives one-signal→one-run (FR-013) for free via the existing supervised path.

**Alternatives rejected**:
- *A separate trigger-event log* — fragments the single legible trace; reuse the one run-log.

## Resolved Technical Context

No unknowns remain. Summary of choices feeding Phase 1:

| Question | Resolution |
|----------|------------|
| Signal origin | Substrate-side `TriggerGateway` GenServer API; no listener/port |
| Event target | All agents whose manifest declares a matching `event` name (default-deny) |
| Message target | Named agent, only if it declares a `message` trigger (default-deny) |
| Input delivery | `:trigger_input` opt → one optional field in the existing stdin JSON |
| Approval shape | `{:approve\|:deny, ref}`; remove-before-act; at-most-once |
| Agent self-approve | Impossible by construction (no agent path into the gateway) |
| Provenance | `event:<name>` / `message` / `approval-resume` in the one run-log; pending shown on inventory |
