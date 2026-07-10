# Phase 0 Research: Agent Lifecycle Controls

All unknowns are resolved from the exploration recorded in the approved design brief and
verified against the current source tree. No NEEDS CLARIFICATION remain.

## R1 — Pause/resume mechanism

- **Decision**: Represent pause as the existing `DeploymentRecord.active` flag. Pause =
  `DeploymentRegistry.mark_inactive/1`; resume = a new `mark_active/1` that flips `active: true`
  while preserving `deployed_at`/`provenance`.
- **Rationale**: `deployed_and_active?/1` already gates event/message dispatch in `TriggerGateway`
  and is re-checked at fire time by `TriggerArming` (`trigger_arming.ex:129`). No new state or
  process is needed; pause automatically covers every trigger path and survives restart (the record
  is durable). Paused (`record exists, active: false`) is already distinguishable from
  never-deployed (`nil`) — `InventoryLive` renders three states today.
- **Alternatives rejected**: A separate "paused" store (redundant with `active`); a per-agent
  GenServer holding paused state (violates Simplicity — no persistent per-agent process exists).
- **Resume ≠ redeploy**: `mark_active/1` must NOT use `record_deployment/3` (that resets
  `deployed_at` and re-fires startup). Resume re-arms time triggers via `TriggerArming.rearm/1` but
  does not fire `:startup` (FR-004).

## R2 — Delete: order of operations and state surfaces

- **Decision**: Delete in this order: (1) `DeploymentRegistry.delete/1` to gate all future dispatch
  first; (2) `TriggerArming.disarm/1` to cancel armed timers; (3) remove files
  (`File.rm_rf("agents/<name>")`, `File.rm("manifests/<name>.md")`); (4) `{:delete_in, [name]}` on
  `spend_ledger`, `provenance`, `conformance`, `judge_results`, `security_review_results`;
  (5) sweep matching `pending_approvals`; (6) leave `data/run_log.md` untouched.
- **Rationale**: Gating dispatch before file/state removal guarantees no run starts mid-delete
  (FR-007). The five per-agent stores are all keyed by `agent_name` at the top level, so a single
  `{:delete_in, [name]}` removes each (`state_store.ex:291` handles the single-key path as a row
  delete). `pending_approvals` nests entries under `[:approvals, ref]`, so it needs the ref-matching
  filter reused from `inventory.ex:63-71`, then `{:delete_in, [:approvals, ref]}` per match.
- **Partial-missing tolerance**: `File.rm_rf/1` is already idempotent (returns `{:ok, _}` for a
  missing dir); `File.rm/1` on a missing manifest returns `{:error, :enoent}` which delete tolerates
  (logs, continues). `{:delete_in, …}` on an absent key is a no-op (`state_store.ex:342`). Delete
  therefore completes cleanup rather than erroring (edge case in spec).
- **Run log preserved**: `data/run_log.md` is global append-only history (Constitution VIII) — not
  per-agent-keyed — and is documented as intentionally untouched (FR-008).
- **In-flight runs**: `RunSupervisor` runs are ephemeral subprocesses; there is no cancel API and
  none is added (FR-007, out of scope). Gating dispatch stops only *future* runs.

## R3 — Schedule edits without reboot (TriggerArming timer refs)

- **Decision**: Change `TriggerArming` `armed` state from `%{agent => [at]}` to
  `%{agent => %{at => timer_ref}}`. `schedule_fn` already returns the ref from `Process.send_after`.
  Add `disarm/1` (cancel every ref for an agent via `Process.cancel_timer`, drop the agent) and
  `rearm/1` (disarm, then reload the manifest via `DeploymentRegistry.get/1` → `manifest_path` and
  arm current `:time` triggers, only if the record exists and is active).
- **Rationale**: Today `armed` keeps no refs, so an old daily timer fires forever after a schedule
  change (`arm_one` only tracks the `at` string). The fire-time check tests only
  `deployed_and_active?`, not the *current* manifest time — so a stale time would keep firing. Timer
  refs make cancellation possible; `rearm` re-reads the manifest so the new time takes effect
  immediately.
- **Stale-fire guard**: A `{:fire, agent, at}` message may already be in the mailbox when a cancel
  lands (the classic `Process.cancel_timer` race). `handle_info({:fire, agent, at}, …)` must re-arm
  the next occurrence **only if `armed[agent][at]` still exists**; otherwise it drops silently. The
  fire itself is still registry-gated, so at most one already-in-flight stale fire executes and no
  new timer is planted for a removed time (FR-010, spec edge case).
- **Test-double impact**: existing test `schedule_fn`s already `make_ref()` (see
  `trigger_arming_test.exs:57-61`), so the shape change is compatible; new tests assert the returned
  ref is cancelled.
- **Alternatives rejected**: Storing an absolute next-fire timestamp and polling (adds a poll loop,
  violates Simplicity); tearing down and rebuilding the whole GenServer on every edit (loses other
  agents' timers).

## R4 — Spend-cap edits

- **Decision**: `update_spend_cap(name, dollars)` validates `dollars > 0` (numeric),
  `Manifest.load/1` → `put_in(manifest.spend.cap, round(dollars * 1_000_000))` → `Projection.write/2`.
- **Rationale**: The cap lives only in the manifest (`spend.cap`, micro-dollars). The gate reloads
  the manifest per evaluation, so a rewrite takes effect on the next spend check with no restart
  (FR-009). `Projection.serialize/1` round-trips faithfully for generated agents (mounts always `[]`,
  not emitted). Accumulated spend lives in the `spend_ledger` store and is untouched by a manifest
  rewrite, so current-window spend is preserved (FR-009).
- **Validation**: reject `<= 0`, non-numeric, and (defensively) a missing/unparseable manifest with a
  typed `{:error, reason}` and zero side effects (FR-009, SC-006). `Projection.write/2` refuses paths
  containing `agents/`, so writes stay under `manifests/`.

## R5 — Trigger-edit validation & manifest rewrite

- **Decision** *(revised by the Phase 6b scope extension)*: `update_triggers(name, triggers)`
  replaces the agent's FULL trigger list — add/remove/retype among exactly
  `startup`/`time`/`event`/`message` — validating atomically, then `Projection.write/2`, then
  `TriggerArming.rearm/1`. The original narrower `update_schedule` (rewrite existing `at`s only)
  was superseded after user trial: real generated agents often carry `triggers: []` or
  startup-only, making a time-only editor a dead surface.
- **Rationale**: Reuse the same `HH:MM` parse rules `TriggerArming` already enforces (hour 0..23,
  minute 0..59); event triggers need a non-empty name; message/startup carry no params. Duplicate
  triggers are rejected (they would double-fire/double-arm); an empty list is a valid inert state.
  An edit never fires startup — startup fires only at deploy completion and boot re-arming.
- **Validation**: any invalid entry or duplicate rejects the whole edit with `{:error, reason}`
  and no write (SC-006). The UI drives row add/remove/retype through LiveView assigns
  (a `phx-change`-synced draft), never JS.

## R6 — UI integration pattern & multi-session refresh

- **Decision**: Follow the existing `test_fire` handler pattern in `InventoryLive`: `phx-click`
  buttons with `phx-value-agent`, a `phx-submit` edit form, handlers that call `AgentLifecycle`, then
  re-run `assign_agents_data/1` + `assign(last_updated: …)` and flash on error. Toggle the per-agent
  edit panel via a `phx-click` assign (no JS). Use `data-confirm` for delete. Broadcast a
  `ProgressEvent` (`stage: :deploy`) on the existing `pipeline:all` topic so other open sessions
  refresh via the already-subscribed `handle_info({:pipeline_progress, …})`.
- **Rationale**: `InventoryLive` already subscribes to `ProgressEvent.all_topic()` and refreshes on
  `{:pipeline_progress, …}` (`inventory_live.ex:311`), so reusing that topic gives cross-session
  refresh (FR-012) with no new PubSub plumbing. `data-confirm` is the established destructive-confirm
  mechanism (no modal library exists). Humanized copy via `AgentOSWeb.HumanText`.
- **Alternatives rejected**: A dedicated PubSub topic (redundant with the firehose); inline JS for the
  edit toggle (violates the global no-inline-JS rule).

## R7 — Testing strategy (Constitution III)

- **Decision**: Unit-test all backend logic test-first (`DeploymentRegistry.mark_active/delete`,
  `TriggerArming.disarm/rearm`/stale-fire, the full `AgentLifecycle` module against temp dirs and
  temp StateStores). Do **not** unit-test the LiveView; cover it via the `quickstart.md` manual
  walkthrough.
- **Rationale**: Constitution III forbids frontend unit tests and mandates test-first backend.
  (Legacy LiveView tests exist under `test/agent_os_web/` for earlier features and are kept green,
  but this feature adds no new ones.) Keeping the view thin (all logic in the tested
  `AgentLifecycle` seam) means the untested surface holds no logic. This is the one deviation from
  the design brief and is logged in the plan's Complexity Tracking.
