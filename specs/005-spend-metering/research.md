# Phase 0 Research: Spend Metering and Real Kill-on-Breach

The two spec-level open decisions were already resolved with the operator during
`/speckit-specify` (recorded in spec Clarifications): **kill granularity = drop the whole
batch** (FR-012) and **meter location = gate / run-worker boundary** (FR-013). The items below
are the remaining design decisions internal to this plan.

## D1: Window-anchor semantics (how "fixed, resetting" is computed)

**Decision**: The window is anchored at the ledger entry's stored `window_start`. The boundary
is `window_start + duration(window)`. When the current time is at-or-after that boundary, the
entry is "rolled over": `spent` resets to `0` and `window_start` re-anchors to the current run
time (`now`). `daily` ⇒ a fixed 24-hour (86 400 s) period.

**Rationale**: The spec mandates a FIXED resetting window keyed off the stored `window_start`
(not a rolling/sliding window, which is explicitly out of scope). Re-anchoring to `now` on
reset is the simplest deterministic rule (Constitution I) and is fully testable with an injected
clock. Repeated idle days do not compound: a single rollover check zeroes `spent` regardless of
how many boundaries were skipped, satisfying the "repeated resets" edge case.

**Alternatives considered**:
- *Calendar-aligned (midnight-UTC) boundaries* — rejected for v2: the spec explicitly says
  calendar alignment is not required, and it adds timezone/DST reasoning for no prototype value.
- *Advancing `window_start` by whole periods on reset (drift-free fixed grid)* — rejected as
  over-engineering for a prototype; re-anchoring to `now` is simpler and the spec permits it.

**Boundary inclusivity**: rollover triggers when `now >= window_start + duration` (i.e.
`DateTime.compare(now, boundary)` is `:gt` or `:eq`). This is independent of the *cap* boundary
inclusivity (FR-009), which is the gate's existing `spent + cost > cap` rule and is unchanged.

## D2: Clock injection mechanism

**Decision**: Pass `now` as an optional argument: `Keyword.get(opts, :now, DateTime.utc_now())`
in `RunWorker.run_once/1`, and an analogous `:now` option on `Inventory.render/1`. The pure
`SpendLedger` functions take `now` as an explicit `DateTime.t()` parameter.

**Rationale**: This is the existing project idiom — `RunWorker` already threads behaviour through
`opts` (e.g. `:items`, `:manifest_path`, `:run_log_path`), and `Scheduler` already passes
`DateTime` values around. A plain default arg is the simplest injectable clock (Constitution I);
no `Clock` behaviour, no Mox, no application-env indirection needed.

**Alternatives considered**:
- *A `Clock` behaviour + Mox* — rejected: heavier than warranted, and Constitution IV is
  satisfied without it since the clock is a pure value.
- *Application env (`Application.get_env(:agent_os, :now)`)* — rejected: global mutable test
  state is worse than an explicit parameter and risks cross-test bleed.

## D3: Intentional-stop signal shape (restart-exemption)

**Decision**: A breach-triggered kill makes `run_once/1` return `{:killed, :spend_breach}` — a
value distinct from `:ok` (success) and `{:error, reason}` (fault). `RunSupervisor.run_loop/2`
gains a clause: `{:killed, _reason} -> :ok` (terminal; no retry, no Alerter).
`RunWorker.run_and_raise/1` gains a matching clause treating `{:killed, _}` as a normal exit
(returns `:ok`, so the Task exits `:normal`).

**Rationale**: FR-006 requires the kill to be *distinguishable* from an abnormal exit. Today the
breach path returns `:ok`, which already happens to avoid restart — but it conflates an
intentional kill with an ordinary successful run, so it is neither explicit nor self-documenting
(Constitution VII). A dedicated tuple makes the intentional stop first-class while leaving the
crash/OOM path (`{:error, {:exit_status, 137}}` → restart-once) completely untouched (FR-007).
Only two callers exist (`run_and_raise`, `run_loop`); both are updated.

**Alternatives considered**:
- *Keep returning `:ok` on breach* — rejected: not distinguishable/explicit per FR-006; a future
  reader cannot tell a kill from a clean run by the return value alone.
- *Raise/exit with a custom reason and let supervision classify it* — rejected: `RunSupervisor`
  drives a plain return-value loop (not OTP restart of a child spec), and the spec's
  "distinguishable from a crash" is cleanest as an explicit non-error return, not a tagged exit.

## D4: Where the shared windowed-entry helper lives

**Decision**: New pure module `AgentOS.SpendLedger` with `duration_seconds/1`, `rolled_over?/3`,
and `current_entry/3` (returns the entry with reset applied). Both `RunWorker` (enforcement,
which then persists the reset via `StateStore`) and `Inventory` (display only) call
`current_entry/3` so the windowed-entry semantics are defined exactly once.

**Rationale**: DRY — enforcement and visibility must agree on "what is this agent's spend right
now," including post-rollover. A pure helper is trivially unit-testable (no GenServer, no clock
side-effect) and keeps `StateStore` as the sole writer (Principle IX): `SpendLedger` only reads
and normalizes; the actual persisted reset is a `StateStore.apply_action/2` performed by
`RunWorker`. The name is generic (no agent vocabulary), satisfying the agent-agnostic clause.

**Alternatives considered**:
- *Put window math directly in `RunWorker`* — rejected: `Inventory` would duplicate it, risking
  the display and the enforcement disagreeing after a rollover.
- *Make `SpendLedger` a GenServer / second writer* — rejected: violates single-writer-per-store
  (Principle IX); `StateStore` already owns `spend_ledger` persistence.

## D5: Persisting the reset

**Decision**: When `RunWorker` detects a rollover before the gate check, it persists the reset
entry (`StateStore.apply_action("spend_ledger", {:put, agent_name, reset_entry})`) so the new
`window_start`/zeroed `spent` are durable and visible to subsequent runs and the inventory. The
post-gate cost increment then builds on the reset value.

**Rationale**: The spec requires the reset to happen "before the run's gate check" and to be
observable per agent. Persisting at detection time keeps the ledger the single source of truth
for both enforcement and the operator render, with no second code path computing the window.

## Constitution alignment

All decisions favour the simplest deterministic mechanism (I), stay strictly within US4 scope
(II), keep tests free of live dependencies via an injected clock and registry costs (IV), and
preserve single-writer state ownership (IX). No NEEDS CLARIFICATION remains.
