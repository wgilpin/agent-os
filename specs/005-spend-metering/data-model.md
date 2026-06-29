# Phase 1 Data Model: Spend Metering and Real Kill-on-Breach

No new persisted store and no schema migration. The entities below are the existing
`spend_ledger` entry (now with a load-bearing `window_start`), the in-memory windowed view
derived from it, the manifest spend constraint, and the new intentional-stop signal.

## Entity: Spend Ledger Entry (persisted, per agent)

The per-agent record inside the single-writer `spend_ledger` store
(`data/spend_ledger.term`). Keyed by `agent_name` (the manifest filename without `.md`).

| Field          | Type            | Meaning |
|----------------|-----------------|---------|
| `spent`        | `non_neg_integer() \| float()` | Cumulative connector cost of executed actions in the current window. |
| `window_start` | `DateTime.t()`  | Anchor of the current fixed window. The boundary is `window_start + duration(window)`. |

- **Single writer**: only `AgentOS.StateStore` (the `"spend_ledger"` instance) mutates it, via
  `{:put, agent_name, entry}`. `SpendLedger`/`RunWorker`/`Inventory` never write directly.
- **Default (no entry yet)**: treated as `%{spent: 0, window_start: now}` — spend zero, window
  anchored at first use.
- **Reset rule**: when `now >= window_start + duration(window)`, the entry becomes
  `%{spent: 0, window_start: now}` (see `SpendLedger.current_entry/3`). `RunWorker` persists this
  reset before the gate check (research D5).
- **Type**: `@type entry :: %{spent: number(), window_start: DateTime.t()}` in
  `AgentOS.SpendLedger` (Constitution V — typed, accessed through the helper).

## Entity: Windowed View (in-memory, derived)

The result of `SpendLedger.current_entry(raw_entry, now, window)` — the same `entry` shape with
the rollover already applied. Consumed by:
- `RunWorker` — uses `.spent` as the gate's starting `spent`, and persists the entry if it
  changed (rollover).
- `Inventory` — uses `.spent` (and the manifest `cap`/`window`) to render `spent / cap / window`.

This is not persisted on its own; it is the canonical "spend right now" both paths agree on.

## Entity: Spend Constraint (manifest, existing — unchanged shape)

`AgentOS.Manifest.Spend` — `%Spend{cap, window, on_breach}`. This feature *consumes* `window`
and `on_breach`, which were previously decorative.

| Field       | Type                         | v2 values | Used by |
|-------------|------------------------------|-----------|---------|
| `cap`       | `non_neg_integer() \| float()` | any number | gate (existing `spent + cost > cap`) |
| `window`    | `:daily`                      | `:daily` only | `SpendLedger.duration_seconds/1` |
| `on_breach` | `:kill`                       | `:kill` only | `RunWorker` on_breach dispatch |

- `window` other than `:daily` and `on_breach` other than `:kill` are out of scope for v2; the
  dispatch matches `:kill` explicitly and `duration_seconds/1` matches `:daily` explicitly.

## Entity: Breach Stop Signal (new, transient)

The return value `{:killed, :spend_breach}` from `RunWorker.run_once/1` when a batch breaches the
cap and `on_breach` is `:kill`.

- **Distinct from**: `:ok` (clean run) and `{:error, reason}` (fault/crash/OOM/timeout).
- **Consumed by**: `RunSupervisor.run_loop/2` (→ terminal, no restart, no Alerter) and
  `RunWorker.run_and_raise/1` (→ `:ok`, Task exits `:normal`).
- **Recorded as**: a `status=killed failure_cause=spend_breach` line in the run log (existing
  breach-branch behaviour, retained), so the kill is legible in the run-trace.

## State transitions

### Spend ledger entry across a run

```text
read raw entry (or default spent=0, window_start=now)
        │
        ▼
SpendLedger.current_entry(entry, now, window)
        │
   rolled over? ── yes ──► entry := {spent: 0, window_start: now}; RunWorker persists reset
        │ no
        ▼
gate.partition_batch(actions, manifest, registry, %{spent: entry.spent})
        │
   any breach? ── yes ──► dispatch on_breach (:kill): drop whole batch (no execution),
        │                 log status=killed, return {:killed, :spend_breach}
        │ no
        ▼
Effector.act_all(approved); spent' = entry.spent + Σ approved cost
StateStore.apply_action("spend_ledger", {:put, agent_name, %{entry | spent: spent'}})
        │
        ▼
return :ok
```

### Supervisor disposition of a run result

```text
run_once result
   :ok                  → success, no restart
   {:killed, :spend_breach} → INTENTIONAL stop, no restart, no Alerter   (NEW)
   {:error, reason}     → fault: retry once; on second failure → Alerter (UNCHANGED)
```

## Validation rules (from requirements)

- **FR-001/002/003**: rollover only when past `window_start + duration(:daily)`; `:daily` ⇒
  86 400 s; no premature reset within a window.
- **FR-004/005**: breach disposition is selected by matching `manifest.spend.on_breach`; `:kill`
  is the only implemented arm and is a real stop (no action executes).
- **FR-006/007**: `{:killed, :spend_breach}` ⇒ no restart; `{:error, _}` ⇒ restart-once
  preserved.
- **FR-008**: `Inventory` renders `spent / cap / window` from the persisted ledger only.
- **FR-009**: cap boundary inclusivity is the gate's existing rule — unchanged.
- **FR-010**: `now` is injectable on both `run_once/1` and `render/1`.
- **FR-011/013**: gate logic and cost model unchanged; meter stays in `RunWorker` post-gate.
- **FR-012**: any breach in a batch drops the whole batch.
