---
description: "Task list for Manifest Enforcement (v2)"
---

# Tasks: Manifest Enforcement (v2)

**Input**: Design documents from `specs/002-manifest-enforcement/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: INCLUDED — Constitution Principle III mandates test-first backend (red→green→refactor),
and the spec calls out gate/spend/credential/world-B tests explicitly. Pure functions and the
gate are written test-first; `:docker` integration is the world-B full-stack proof.

**Organization**: Tasks are grouped by user story (US1–US6 from spec.md) so each story is an
independently testable increment. Dependency order overrides priority where a P1 story (US6)
must follow the stories it exercises.

## Path Conventions

Single project, BEAM control plane (`lib/agent_os/`, `test/agent_os/`) + Python agent
(`agents/discovery/`). Paths are from plan.md §Project Structure.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Wire the new substrate-owned state mounts and config so later phases have somewhere
to persist spend and parked approvals.

- [ ] T001 Add `spend_ledger` and `pending_approvals` StateStore mounts to the supervision tree in `lib/agent_os/application.ex` (single-writer per mount, isolated term-files), mirroring the existing `roster_trust` mount. Model `pending_approvals` data as a map keyed by `ref` (`%{ref => entry}`) stored under one key, so add/clear are whole-map `{:put, ...}` writes — no new StateStore delete op required (resolves the missing-delete gap)
- [ ] T002 [P] Add mount paths + spend defaults (`window: daily`, `on_breach: kill`) and the `:test` autostart=false handling for the new mounts in `config/config.exs`
- [ ] T003 [P] In `test/test_helper.exs`, add per-test startup helpers for the `spend_ledger` and `pending_approvals` mounts against isolated temp term-files (never live state)

**Checkpoint**: App boots with the two new mounts; tests can start them in isolation.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The manifest schema (scope-only grants + spend) and the connector capability registry
(intrinsic danger). Everything downstream — gate, credential proxy, spend, triggers — depends on
these. NO user story can proceed until this phase is complete.

- [ ] T004 [P] Write `AgentOS.Manifest.Grant` struct (`connector`, `recipients`, `methods`; typespec, `@moduledoc`) in `lib/agent_os/manifest/grant.ex` per data-model.md
- [ ] T005 [P] Write `AgentOS.Manifest.Spend` struct (`cap`, `window`, `on_breach`; typespec, `@moduledoc`) in `lib/agent_os/manifest/spend.ex` per data-model.md
- [ ] T006 [P] Write manifest-parser tests in `test/agent_os/manifest_test.exs`: parse `grants[]` → `Grant` structs, `spend{cap,window,on_breach}` → `Spend`, `triggers` incl. `event`/`message`; malformed/missing grants or `spend`, or a `connector` absent from the registry → **loud failure** (FR-016)
- [ ] T007 Extend `lib/agent_os/manifest.ex` to parse frontmatter into `Grant`/`Spend` structs + typed triggers and fail loudly on malformed input (make T006 green); keep `Manifest.load/1` mechanism
- [ ] T008 [P] Write connector-registry tests in `test/agent_os/connector_test.exs`: registry exposes `%{mutating?, requires_approval?, credential, cost}` per connector; generic names; lookup of an unknown connector errors (per contracts/connector-registry.md)
- [ ] T009 Implement `AgentOS.Connector` behaviour + capability registry in `lib/agent_os/connector.ex`: entries `kv_append` (mutating, no approval, no credential, cost 1) and `external_send` (mutating, requires_approval, credential `:outbound_token`, cost 2, backed by a **mock sink**); generic names only (make T008 green)
- [ ] T010 Update `manifests/discovery.md` to the v2 schema: `grants:` as `{connector, recipients, methods}` (kv_append; external_send→owner-inbox), `spend:{cap,window,on_breach}`, and a `message` trigger (per contracts/manifest-schema.md)
- [ ] T011 Update the hard-wired `config :agent` grant shape in `config/config.exs` and rewrite `Provisioner.check_drift/0` in `lib/agent_os/provisioner.ex` to compare the new `{connector, recipients, methods}` + `spend{cap,window,on_breach}` shape; add a drift test to `test/agent_os/provisioner_test.exs`

**Checkpoint**: Manifest parses into typed structs; registry classifies connectors; provisioning
loads the enforced manifest and fails loud on malformed. Foundational complete.

---

## Phase 3: User Story 1 — Every action checked against the declared envelope (P1) 🎯 MVP

**Goal**: A deterministic gate validates every proposed action against grant scope (manifest) +
connector danger/cost (registry) + spend, in front of the effector chokepoint; only `:approve`
executes (default-deny).

**Independent Test**: Feed the gate one in-scope action and out-of-scope variants (wrong recipient,
wrong method, ungranted connector); assert the in-scope one reaches the effector and each
out-of-scope one is rejected with a logged reason — deterministic stub, no live model.

- [ ] T012 [P] [US1] Write gate tests in `test/agent_os/gate_test.exs` covering the full decision order (shape → grant match → recipient → method → spend → approval → approve), each `:reject` reason, `:breach`, `:needs_approval`, default-deny, and "scope from grant / danger from registry"; the gate consumes a typed `AgentOS.ProposedAction` (per contracts/gate.md)
- [ ] T012a [P] [US1] Write `AgentOS.ProposedAction` struct (`type`, `recipient`, `method`, `payload`; typespec, `@moduledoc`) in `lib/agent_os/proposed_action.ex`, with a `from_map/1` that validates the decoded agent output into the struct (untrusted input → typed, Principle V)
- [ ] T013 [US1] Implement `AgentOS.Gate.evaluate/4` (`%ProposedAction{}, manifest, registry, spend_ledger`) returning `{:approve,grant}|{:needs_approval,grant}|{:reject,reason}|{:breach,:spend}` with loud logging on every reject/breach (make T012 green) in `lib/agent_os/gate.ex`
- [ ] T014 [US1] Add a list-level partition helper to `lib/agent_os/gate.ex` that splits a batch of proposed actions into approved / parked / rejected / breached, preserving order
- [ ] T015 [US1] Refactor `lib/agent_os/effector.ex` to dispatch by the grant's connector via the registry (remove the hard-coded `"record_signal"`/`"append_digest"` clauses — Principle IX de-leak); execute only gate-approved actions
- [ ] T016 [US1] Update `test/agent_os/effector_test.exs` to assert only gate-approved actions execute and dispatch goes through the registry (replace the old type-membership expectations)
- [ ] T017 [US1] Wire `Gate` into `lib/agent_os/run_worker.ex` in place of the bare `OutputCheck.validate` call: decode agent output and build typed `AgentOS.ProposedAction` structs via `from_map/1` (T012a), load registry, snapshot spend ledger, evaluate batch, act on approvals; fold/retire `lib/agent_os/output_check.ex` shape-check into the gate
- [ ] T018 [US1] Update `agents/discovery/main.py` so the stub emits actions typed by **connector** (`kv_append`, optional `external_send`) with `recipient`/`method` fields per the published action schema in `contracts/boundary.md` (the schema IS that contract — no separate artifact); keep domain vocabulary (digest/roster) in the payload only
- [ ] T019 [P] [US1] Extend the run-log schema/append in `lib/agent_os/run_log.ex` to record gate decisions (approved/rejected count + reasons) for legibility (Principle VIII)

**Checkpoint**: US1 independently testable — the gate enforces the envelope end-to-end; out-of-scope
actions never reach the effector. **This is the MVP.**

---

## Phase 4: User Story 2 — The manifest is invisible to the agent (P1)

**Goal**: Verify (the architecture already holds) that the manifest's grants/caps/constraints never
cross the port boundary nor mount into the container.

**Independent Test**: Inspect the serialized boundary payload and the container mount set for a run;
assert no manifest grant/constraint/spend key appears in either.

- [ ] T020 [P] [US2] Write a boundary-invariant test in `test/agent_os/boundary_test.exs`: the JSON `run_worker` sends contains only `{state, items}` (+ action schema) and none of `grants/recipients/methods/cost/requires_approval/spend.*`; and `Sandbox.build_argv/1` mount set excludes the manifest path (per contracts/boundary.md)
- [ ] T021 [US2] Add an explicit invariant note to the `@moduledoc` of `lib/agent_os/run_worker.ex` and `lib/agent_os/manifest.ex` stating the manifest is gate-only and never crosses the boundary (guards against regression)

**Checkpoint**: US2 independently testable — manifest content provably absent from agent-reachable surfaces.

---

## Phase 5: User Story 3 — No LLM-running component holds a mutating credential (P1)

**Goal**: A credential proxy holds capabilities and injects a credential at the chokepoint at action
time for credentialed connectors; the agent never holds a mutating credential.

**Independent Test**: Inspect the agent env/boundary payload for any mutating credential (assert
none); drive an approved `external_send` and confirm the credential is present only inside the
chokepoint at injection time.

- [ ] T022 [P] [US3] Write credential-proxy tests in `test/agent_os/credential_proxy_test.exs`: proxy holds caps keyed by registry `credential` id; `with_credential/2` exposes the secret only inside the injected fun; the secret is never logged/persisted; agent env + boundary payload contain no mutating credential (FR-008/FR-009, SC-004)
- [ ] T023 [US3] Implement `AgentOS.CredentialProxy` (GenServer holding caps from app/OS env, keyed by credential id; `with_credential(credential_id, fun)`) in `lib/agent_os/credential_proxy.ex`; add it to the supervision tree in `lib/agent_os/application.ex`
- [ ] T024 [US3] Wire the proxy into `lib/agent_os/effector.ex`: when an approved action's connector declares a `credential` in the registry, obtain it from the proxy and inject at the mock-sink call site; never pass it to the agent
- [ ] T025 [US3] Implement the `external_send` mock sink connector body (records the delivered payload to a test-observable sink) in `lib/agent_os/connector.ex`, executed only with an injected credential

**Checkpoint**: US3 independently testable — credentialed action runs via chokepoint injection; no mutating credential anywhere the agent can read.

---

## Phase 6: User Story 4 — Spend capped, metered, visible; breach kills (P2)

**Goal**: Spend = summed connector cost over a fixed window, metered at the chokepoint; a breach
fires a real `kill` that ends the run without triggering restart-once-and-alert.

**Independent Test**: With a small cap, drive actions until the meter would exceed it; assert the
action at the cap is allowed, the action over it is killed per `on_breach`, spend is per-agent
visible, and no restart is attempted.

- [ ] T026 [P] [US4] Write spend-meter tests in `test/agent_os/spend_meter_test.exs`: fixed-window accumulation, cap-boundary (`==cap` allowed, `>cap` breach), window reset to zero, per-agent attribution (FR-010a/FR-011, SC-005)
- [ ] T027 [US4] Implement `AgentOS.SpendMeter` (pure fixed-window accounting + `spend_ledger` StateStore persistence; cost read from the registry, not the manifest) in `lib/agent_os/spend_meter.ex`
- [ ] T028 [US4] Integrate the meter at the chokepoint: `Gate`/`run_worker` checks `spent + registry.cost` pre-execution and increments the ledger on each executed action in `lib/agent_os/run_worker.ex`
- [ ] T029 [US4] Implement breach handling in `lib/agent_os/run_worker.ex`: a `{:breach,:spend}` ends the run via a **non-error terminal** status logged `killed: :spend_breach` (NOT `{:error,_}`), so `RunSupervisor.run_loop` neither retries nor alerts (FR-012/FR-013)
- [ ] T030 [P] [US4] Add a breach-vs-crash test in `test/agent_os/run_supervisor_test.exs`: a spend breach does NOT restart; a genuine child crash still restart-once-and-alerts (SC-006)
- [ ] T031 [P] [US4] Expose per-agent spend for the current window in `lib/agent_os/inventory.ex` (read without asking the agent — Principle VIII) and assert it in `test/agent_os/inventory_test.exs`

**Checkpoint**: US4 independently testable — cap enforced at the chokepoint; breach kills intentionally; spend visible.

---

## Phase 7: User Story 5 — Event- and message-triggers; approval as event (P2)

**Goal**: Runs fire from in-BEAM event/message triggers; approval is an event-trigger with
park-and-resume (no blocking process).

**Independent Test**: Emit an event and a message into the substrate (each fires exactly one gated
run); park a `requires_approval` action and assert it proceeds only after the approval event.

- [ ] T032 [P] [US5] Write trigger/approval tests in `test/agent_os/trigger_bus_test.exs`: `event/2` and `message/1` each fire exactly one gated run tagged `:event`/`:message`; a `requires_approval` action parks (run completes) and resumes through the gate+effector on the matching approval event; an approval for an unknown ref is logged+ignored; approval-never-arrives ends terminal with the action still pending (FR-014/FR-015, SC-007)
- [ ] T033 [US5] Implement `AgentOS.TriggerBus` (GenServer; `event(name,payload)` / `message(payload)` casts → `RunSupervisor.start_run/1` tagging `trigger:`) in `lib/agent_os/trigger_bus.ex`; add to supervision tree in `lib/agent_os/application.ex`
- [ ] T034 [US5] Implement park-and-resume in `lib/agent_os/run_worker.ex`: on `{:needs_approval,grant}` add a `PendingApproval{ref,action,grant}` to the `pending_approvals` map via `{:put, ...}` and complete the run; on a `{:event,{:approval,ref}}` load + re-validate through the gate + effector, then clear the entry by writing the map without `ref` (whole-map `{:put, ...}`, per T001 shape)
- [ ] T035 [US5] Confirm `lib/agent_os/scheduler.ex` is one trigger source among bus triggers (time trigger still tags `:timer`); add a brief `@moduledoc`/comment noting the trigger model — no behavioural change

**Checkpoint**: US5 independently testable — event/message triggers and approval park-and-resume work.

---

## Phase 8: User Story 6 — World B holds against a hostile agent (P1)

**Goal**: Prove an adversarial agent cannot breach the manifest — blocked in all three categories at
the gate, effector never executes. (Depends on US1 gate, US3 credential path, US4 spend.)

**Independent Test**: Run the adversarial stub; assert each hostile proposal (out-of-scope recipient,
over-cap spend, ungranted method/connector) is rejected/breached and the effector never runs.

- [ ] T036 [P] [US6] Create `agents/discovery/adversarial_stub.py`: a hostile agent that emits (a) `external_send` to an out-of-scope recipient, (b) actions exceeding the spend cap, and (c) an ungranted connector/method
- [ ] T037 [US6] Add the adversarial image build to `scripts/agent_image.sh` (or a tagged variant) so the `:docker` test can run it
- [ ] T038 [US6] Write the full-stack world-B test in `test/agent_os/world_b_test.exs` (`@tag :docker`): run the adversarial stub end-to-end and assert all three breach categories are physically blocked at the gate with the effector never executing (FR-017, SC-008)

**Checkpoint**: US6 independently testable — world B proven by an adversary, not a cooperative run.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Quality gates and cleanup across all stories.

- [ ] T039 [P] Run `mix format` + Credo and resolve Dialyzer warnings for all new/changed Elixir modules (Quality Gates)
- [ ] T040 [P] Run `ruff` + `mypy` clean on `agents/discovery/main.py` and `agents/discovery/adversarial_stub.py`
- [ ] T041 [P] Ensure every new function/module has a purpose `@doc`/`@moduledoc` (Principle VII) across the new `lib/agent_os/` modules
- [ ] T042 Remove `lib/agent_os/output_check.ex` if fully folded into the gate (and drop its references/tests), confirming no dead code remains (Principle I/II)
- [ ] T043 Validate `specs/002-manifest-enforcement/quickstart.md` end-to-end (gated run, event/message triggers, approval, breach kill, world-B `--only docker`) and fix any drift

---

## Dependencies & Execution Order

- **Setup (Phase 1)** → **Foundational (Phase 2)** must complete before any user story.
- **US1 (P1)** depends on Foundational. It is the **MVP** and the integration seam for the rest.
- **US2 (P1)** depends on Foundational; testable right after US1 (boundary/run_worker exist).
- **US3 (P1)** depends on Foundational + US1 (effector dispatch wired).
- **US4 (P2)** depends on Foundational + US1 (chokepoint).
- **US5 (P2)** depends on Foundational + US1 (gate `:needs_approval` + run_worker pipeline).
- **US6 (P1)** depends on **US1 + US3 + US4** — it exercises all three breach categories, so despite
  being P1 it sequences after them. (US1's `gate_test` already gives the deterministic unit-level
  adversary; US6 is the full-stack `:docker` proof.)
- **Polish (Phase 9)** last.

Recommended order: Setup → Foundational → US1 → US2 → US3 → US4 → US5 → US6 → Polish.

## Parallel Opportunities

- **Phase 1**: T002, T003 in parallel after T001.
- **Foundational**: T004, T005, T006, T008 in parallel (different files); T007 after T004–T006; T009
  after T008; T010/T011 after structs exist.
- **Within a story**: the `[P]` test task is written first and can be authored in parallel with
  scaffolding, but its implementation task (same module) is sequential.
- **Across stories**: US2's test (T020) can be authored in parallel with US1 implementation since it
  only asserts existing boundary behaviour.

## Implementation Strategy

- **MVP = Phase 1 + Phase 2 + US1.** That delivers the deterministic gate enforcing the manifest —
  the core of "v2" and the hard dependency of v3.
- Layer US2/US3 (the other two P1 invariants), then US4/US5 (P2), then close with US6 — the world-B
  acceptance gate that certifies "v2 done."
- Keep every phase green (Constitution III/IV) before moving on; no live LLM or live external service
  enters any test.

## Task Summary

- **Total tasks**: 44
- **Per story**: Setup 3 · Foundational 8 · US1 9 · US2 2 · US3 4 · US4 6 · US5 4 · US6 3 · Polish 5
- **Test tasks (TDD)**: T006, T008, T012, T020, T022, T026, T030, T031, T032, T038
- **Suggested MVP**: Setup + Foundational + US1 (T001–T019, incl. T012a)
