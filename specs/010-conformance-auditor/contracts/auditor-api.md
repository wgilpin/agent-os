# Contract: ConformanceAuditor API

Module: `AgentOS.ConformanceAuditor`. Internal Elixir interface (no external/network surface).

## `audit/2` — pure decision function (the load-bearing, fully unit-tested surface)

```elixir
@spec audit([RunRecord.t()], String.t(), keyword()) :: Verdict.t()
def audit(records, purpose, opts \\ [])
```

- **Inputs**: parsed run records (already windowed or full — see opts), the agent's stated `purpose`
  (used for identity/framing only in this slice — no semantic judgement), and `opts`:
  - `:agent` — agent name (defaults derived by caller from manifest basename).
  - `:window` — N (default 20).
  - `:quiet_streak` — default 3.
  - `:denied_threshold` — default 3.
  - `:now` — `DateTime.t()` for `computed_at` provenance only (default `DateTime.utc_now()`).
- **Output**: a `Verdict.t()`.
- **Invariants**:
  - **Pure & deterministic**: same `records` + `opts` ⇒ identical verdict, independent of any global
    state, agent runtime, or wall-clock (the clock affects only `computed_at`, never a threshold).
  - **FLAG-ONLY**: the return type is a `Verdict` of flags; there is **no** return value, option, or
    side effect that yields a pass, approval, deploy-gate, or any boundary-crossing outcome (FR-001).
  - **Non-redundant**: never inspects `rejected_count` for Leg 2a; never reports recipient/method/type/
    spend conditions the gate enforces (FR-003).
  - **Totality**: every applicable flag is present in `flags` (FR-007).

## `run_pass/1` — orchestration (side-effecting wrapper)

```elixir
@spec run_pass(keyword()) :: Verdict.t()
def run_pass(opts \\ [])
```

Steps (each step delegates; the wrapper holds no decision logic):
1. Resolve agent name + manifest purpose (`Manifest.load/1`, basename key).
2. `records = RunLog.read_records(run_log_path, window: N)`.
3. `previous = StateStore.snapshot("conformance")[agent]`.
4. `verdict = audit(records, purpose, opts)`.
5. Persist: `StateStore.apply_action("conformance", {:put, agent, verdict})` (existing handler).
6. For each flag in `verdict` that is newly raised or escalated vs `previous`:
   `ConformanceAuditor.Alert.emit(agent, flag, opts)` (Decision 5).
7. Return `verdict`.

- **Invariant**: `run_pass/1` may write the verdict store and `data/admin_alerts.md` only. It MUST NOT
  write `data/run_log.md`, call the gate/effector, or alter any deploy/action path (FR-013, Principle XI).

## `AgentOS.ConformanceAuditor.Scheduler` — daily trigger

A self-rescheduling GenServer mirroring `AgentOS.Scheduler`: arms `Process.send_after(self(), :fire, ms)`,
on `:fire` calls `run_pass/1` then re-arms. Configurable `:run_hour`; `:run_fn` injectable for tests.
Added to the supervision tree in `application.ex` (only under `:autostart`).

## `AgentOS.ConformanceAuditor.Alert` — notification-only sink

```elixir
@spec emit(String.t(), Flag.t(), keyword()) :: :ok
```

`Logger.warning(...)` + append one line to `data/admin_alerts.md` (path overridable via opts for tests).
MUST NOT touch `data/run_log.md`. Returns `:ok`; has no return path that influences any outcome.

## `AgentOS.RunLog.read_records/2` — multi-record parser (new)

```elixir
@spec read_records(Path.t(), keyword()) :: [RunRecord.t()]
```

Reads the run-log, keeps lines containing `status=` (excludes `digest:`), parses each into a
`RunRecord`, skips unparsable lines with a `Logger.warning`, and returns the **last** `:window` records
(default all) in chronological order. Existing `Inventory.parse_last_run/1` is left untouched.
