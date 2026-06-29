# Phase 1 Data Model: Event-, Message-, and Approval-as-Event Triggers

This feature introduces no new persistent store and no schema change. It defines the **in-flight
admitted-signal** shapes the gateway accepts, and reuses the existing `pending_approvals` entry and
run-log provenance field. All Elixir types carry `@type`/`@spec` (Constitution V); no bare maps cross a
function boundary.

## 1. Admitted Signal (transient, gateway intake)

The single value the substrate-side intake accepts. It is never persisted; it exists only for the duration
of one dispatch. Three variants:

```text
admitted_signal ::
    {:event, name :: String.t(), payload :: term()}      # named external event + its payload
  | {:message, agent :: String.t(), content :: term()}   # message addressed to a named agent
  | {:approval, decision :: :approve | :deny, ref :: String.t()}  # human approval/denial of a held action
```

**Origin invariant**: an `admitted_signal` may only be constructed by substrate-side callers of the
`TriggerGateway` API. It is never derived from agent stdout or from untrusted web input (FR-010, R1/R5).

**Validation**:
- `:event` — `name` non-empty string; `payload` any JSON-encodable term (treated as untrusted run input).
- `:message` — `agent` names an agent present in the inventory; `content` any JSON-encodable term.
- `:approval` — `decision ∈ {:approve, :deny}`; `ref` a non-empty string matching the stored ref format.
- A malformed signal is rejected at intake with a log line and fires nothing (FR — edge: malformed payload).

## 2. Trigger Declaration (existing, manifest — unchanged)

Already parsed by `Manifest.parse_trigger!/1` ([manifest.ex:149-167](../../lib/agent_os/manifest.ex)).
Reused as the **allowlist** the gateway matches against; no field added.

```text
trigger ::
    %{type: :time, at: String.t()}     # fired by Scheduler (unchanged)
  | %{type: :event, name: String.t()}  # NOW ACTIVE — matched by admitted :event name
  | %{type: :message}                  # NOW ACTIVE — enables :message delivery to this agent
```

**Matching rules** (default-deny):
- `:event, name` fires an agent **iff** that agent's manifest contains `%{type: :event, name: ^name}`.
- `:message, agent` fires **iff** that agent's manifest contains `%{type: :message}`.
- No matching declaration ⇒ no run (FR-002, FR-004).

## 3. Pending Approval Entry (existing store — read & remove only)

Lives in the `pending_approvals` `StateStore`, persisted to `data/pending_approvals.term`, shape already
written by `RunWorker` ([run_worker.ex:288-300](../../lib/agent_os/run_worker.ex)):

```text
pending_approvals :: %{approvals: %{ref :: String.t() => pending_entry}}

pending_entry :: %{
  ref :: String.t(),                 # stable id, e.g. "ref_<unique_positive_integer>"
  action :: ProposedAction.t(),      # the held action, already gate-classified needs_approval
  grant :: Manifest.Grant.t()        # the grant it was matched against
}
```

**State transitions** (the only new behaviour over this store):

```text
(absent) --gate parks a needs_approval action--> PENDING(ref)        [existing: RunWorker writes]
PENDING(ref) --{:approval,:approve,ref}--> (removed) then Effector.act(entry)   [NEW: execute once]
PENDING(ref) --{:approval,:deny,ref}-->    (removed, not executed)              [NEW: drop]
PENDING(ref) --{:approval,_,other_ref}-->  PENDING(ref) unchanged               [NEW: no-op]
(absent) --{:approval,_,ref}-->            (absent), logged no-op               [NEW: unknown ref]
```

**Invariants**:
- Remove-before-execute (single-writer `StateStore`) ⇒ a parked action executes **at most once**
  regardless of duplicate `:approve` (FR-013, R4).
- A `PENDING(ref)` persists across the end of the run that created it; a later approval still executes it
  (FR-014).
- Only the gateway transitions this store on approval; the agent has no path to it (FR-009).

## 4. Run Input (transient — delivered to the fired run)

The payload/content carried into the fired run as its hand-input, via the new `:trigger_input` opt threaded
`TriggerGateway → RunSupervisor.start_run → RunWorker → build_payload`. Included as one optional field in
the existing stdin JSON line; absent for timer fires (R3).

```text
run_input :: term() | nil   # event payload or message content; nil when the trigger carries none
```

## 5. Trigger Provenance (existing run-log field — value set extended)

The `trigger=` token already stamped into `data/run_log.md` and parsed by `Inventory`
([run_log.ex:45](../../lib/agent_os/run_log.ex), [inventory.ex:106](../../lib/agent_os/inventory.ex)).
Value set extended:

```text
trigger_provenance ::
    "timer" | "manual"          # existing
  | "event:" <> name            # NEW — event fire, carries the matched event name
  | "message"                   # NEW — message fire
  | "approval-resume"           # NEW — a held action executed via approval (no new agent run)
```

No other run-log field changes. The standing inventory additionally renders the current `pending_approvals`
entries (ref + a short action summary) so what awaits approval is legible without asking the agent
(FR-012, Principle VIII).
