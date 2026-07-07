# Phase 1 Data Model: Run-Worker Transcript Migration

This feature adds one small typed struct and *reads* existing ones. Nothing new is
persisted; the transcript, spend ledger, and pending-approvals stores already exist.

## New — `AgentOS.OutcomeRecord`

The terminal result an agent prints to stdout. Replaces the ad-hoc `%{"actions" => …}`
map match in the run worker.

| Field    | Type          | Rules                                              |
|----------|---------------|----------------------------------------------------|
| `outcome`| `String.t()`  | Required, non-empty. e.g. `"completed"`, `"refused"`. |
| `reason` | `String.t()`  | Required. Human-readable; may be empty string but key MUST be present. |

**Operations**
- `parse(stdout :: String.t()) :: {:ok, t()} | {:error, :malformed}`
  - Decodes one line of JSON. Success requires both `"outcome"` and `"reason"` keys with
    string values. Anything else (including legacy `{"actions": …}`, non-JSON, missing
    key, non-string value) → `{:error, :malformed}`.

**Placement**: new module `lib/agent_os/outcome_record.ex` (or nested under RunWorker if
preferred at implementation time; the module boundary is the contract, not the file).

## Read-only — `AgentOS.ActionTranscript` (existing, unchanged)

Source of what the agent did. Keyed by `run_token`, single-writer (rail writes; worker
reads). See `lib/agent_os/action_transcript.ex`.

| Field       | Type                | Notes                                  |
|-------------|---------------------|----------------------------------------|
| `run_token` | `String.t()`        | Key.                                   |
| `mode`      | `:live \| :record \| nil` | Copied from broker registration.  |
| `entries`   | `[Entry.t()]`       | Append-only per run.                   |

**`Entry`** (existing): `kind :: :granted | :parked | :rejected`, plus `connector`,
`method`, `arguments`, `result`, `reason_code`.

**Derived tally (computed by the run worker, not stored)**

| Run-log field    | Derivation from `entries`                          |
|------------------|----------------------------------------------------|
| `approved_count` | count of `kind == :granted`                        |
| `parked_count`   | count of `kind == :parked`                         |
| `rejected_count` | count of `kind == :rejected`                       |
| `gate_reasons`   | unique `reason_code` over `kind == :rejected`      |
| `actions`        | `approved_count` (RunLog's headline effect count)  |

## Read-only — `spend_ledger` store (existing, unchanged)

Per-agent spend, maintained by the broker/rail during inference. The worker reads it
before and after the run to decide breach; it no longer writes approved-action cost.

| Field         | Type       | Notes                                    |
|---------------|------------|------------------------------------------|
| `spent`       | integer µ$ | Compared against `manifest.spend.cap`.   |
| `window_start`| `DateTime` | Managed via `AgentOS.SpendLedger`.       |

## Read-only — `pending_approvals` store (existing, unchanged)

Written by the rail's parking arm. The worker reads parked entries from the *transcript*
for its tally and does **not** insert into this store (removing the old parking loop).

| Field       | Type   | Shape per ref                                  |
|-------------|--------|------------------------------------------------|
| `approvals` | map    | `ref => %{ref, action: %ProposedAction{}, grant: %Grant{}}` |

## State transitions (run disposition)

```
stdout parses as OutcomeRecord? ──no──▶ run logged :error, failure_cause "malformed_outcome"
        │yes
        ▼
spent >= cap (post-run ledger)? ──yes──▶ dispatch_on_breach (counts from transcript)
        │no
        ▼
run logged :ok  (actions/approved/parked/rejected/gate_reasons from transcript)
```

Port failure (crash/oom/timeout) is detected before parsing and logged `:error` with the
existing `failure_cause` mapping — unchanged.
