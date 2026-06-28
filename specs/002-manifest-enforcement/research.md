# Phase 0 Research: Manifest Enforcement (v2)

All Technical Context unknowns are design decisions over the *existing* Phase 1/2 codebase
(no new technology is introduced). Each decision below records what was chosen, why, and the
alternatives rejected. The five clarification answers (spec §Clarifications, Session
2026-06-28) are treated as settled inputs.

## D1 — Gate placement relative to `OutputCheck`

- **Decision**: Introduce `AgentOS.Gate` as the deterministic validator and call it from
  `run_worker` at the point that today calls `OutputCheck.validate/2`. `OutputCheck` is
  reduced to a shape/`"type"`-presence pre-filter (or folded into the gate's first stage); the
  type-membership and all new constraint/spend checks live in `Gate`. The effector executes
  only gate-approved actions.
- **Rationale**: `OutputCheck` already sits exactly at the chokepoint (`OutputCheck.validate →
  Effector.act_all`). The gate is the grown-up version of that check, so reusing the seam keeps
  the change minimal (Principle I) and means the effector path is unchanged in shape.
- **Alternatives rejected**: A separate gate process/GenServer — adds a message hop and a
  lifecycle for a pure, synchronous decision. The gate is a pure function over (action,
  manifest, spend snapshot); it does not need to own state.

## D2 — Manifest grant schema & typed parsing (scope only)

- **Decision**: Replace the flat `connectors:`/`outputs:` lists with a `grants:` list where each
  entry is a `Grant`: `{connector, recipients, methods}` — **scope only**. Intrinsic danger
  (`requires_approval?`, `credential`, `cost`) does NOT live in the grant; it lives in the
  connector capability registry (see D9). `spend:` gains `window` and `on_breach`. Parse into
  `AgentOS.Manifest.Grant` and `AgentOS.Manifest.Spend` structs (Principle V). Keep `purpose`,
  `mounts`, `owner`, `supervision`, `triggers`.
- **Rationale**: The spec requires recipient/method scoping to live in the manifest and be read
  by a generic gate (FR-002, Principle IX). But approval/credential/cost are properties of the
  *capability*, not author choices — keeping them out of the grant prevents an author (human now,
  machine in v3) from downgrading a dangerous connector. The manifest stays the source of truth
  for *what this agent may do and to whom*; the registry is the source of truth for *how
  dangerous each capability is*.
- **Alternatives rejected**: A per-grant `requires_approval`/`cost` (earlier draft of this plan)
  — unsound: an author could set `requires_approval: false` on an external send and defeat the
  gate, which is exactly what v2 must prevent before v3 generation. Flat lists + gate-side
  scoping — violates "scoping lives in the manifest" and Principle IX. Bare maps — violates V.
- **Migration note**: `provisioner.check_drift/0` compares config grants to the manifest; it is
  updated to compare the new `{connector, recipients, methods}` shape, and the hard-wired
  `config :agent` grants change shape so drift detection still holds.

## D3 — Keeping the manifest off the boundary (verify, don't rebuild)

- **Decision**: No new mechanism. `run_worker` already serializes only
  `%{"state" => …, "items" => …}` across the port; the manifest is loaded host-side and used only
  by the gate. Add a **contract test** asserting the boundary payload and the container mount set
  contain none of the manifest's grants/caps/constraints, plus an explicit moduledoc invariant.
- **Rationale**: US2/FR-006 are satisfied by the current architecture; the risk is *regression*,
  not absence. A guarding test is the right, simplest response (Principle I).
- **Alternatives rejected**: Encrypting/redacting a manifest view for the agent — unnecessary;
  the agent never receives any manifest view at all.

## D4 — Credential proxy & the mock connector

- **Decision**: `AgentOS.CredentialProxy` holds capabilities keyed by the **registry credential
  id** (e.g. `:outbound_token`) and exposes `with_credential(credential_id, fun)` that injects
  the secret only inside the effector's call. The registry (D9) says which credential a connector
  needs; the effector looks it up and asks the proxy at action time. The agent never receives the
  credential (not in env, not in the boundary payload).
- **Rationale**: FR-008/FR-009 require a credential injected at the chokepoint with no
  LLM-running component holding it. The existing actions write to local `StateStore` and need no
  credential, so a representative credentialed action is required to make the proxy demonstrable
  and testable (see Complexity Tracking). A mock sink keeps it deterministic (Principle IV).
- **Alternatives rejected**: Wire a real external API + key now — violates Principle IV (live
  dependency) and Phase 2's "no live egress yet" stance. Inject the credential into the container
  — exactly what FR-009 forbids.
- **Storage at rest**: capabilities are read from application env / OS env at boot into the proxy
  process state; never written to the term-file, never logged. (The concrete secret store can
  harden later; v2 proves the *boundary*, not secret management.)

## D5 — Spend: fixed-window accounting & cap boundary

- **Decision**: `AgentOS.SpendMeter` computes spend as the **sum of executed actions' costs**
  (each action's cost comes from its connector in the registry — D9 — not from the manifest)
  within a **fixed window** (resets at the period boundary), persisted as a per-agent ledger
  mount in `StateStore`. Metering happens at the chokepoint, *before* executing each action: if
  `current + cost ≤ cap`, allow and add; if `current + cost > cap`, it is a breach.
  (Cap-boundary: an action landing spend exactly at `cap` is allowed; the next over-cap action
  breaches — FR-011, spec Edge Cases.)
- **Rationale**: Matches the three clarification answers (per-action cost, fixed window, kill).
  Pre-execution metering is what makes the cap an actual ceiling rather than a post-hoc report.
- **Alternatives rejected**: Rolling window (rejected in clarify — needs per-action timestamps);
  metering after execution (lets a breach action through once).

## D6 — Breach kill without restart-once-and-alert

- **Decision**: A spend breach makes `run_worker.run_once/1` return a **non-error terminal
  status** (e.g. `:ok` with a `killed: :spend_breach` run-log entry), NOT `{:error, …}`.
  `RunSupervisor.run_loop` only retries on `{:error, …}`, so a non-error return neither retries
  nor alerts. The run-log records the kill explicitly for legibility.
- **Rationale**: FR-012/FR-013 — the kill must be real (remaining actions are not executed and
  the run terminates) but intentional (no restart). The existing supervisor already distinguishes
  error from success; we route a breach to the success-shaped path with a distinct logged status.
- **Alternatives rejected**: Raising/`{:error,…}` on breach — would trigger the retry loop and an
  alert, contradicting "intentional stop". A new supervisor flag — more machinery than needed.
- **Note**: Because the agent is one-shot (proposes all actions, then the container exits), the
  "kill" halts the effector's remaining-action loop; no mid-flight container kill is required at
  v2. The container-kill machinery from Phase 2 (cidfile + trap) remains for crash/timeout paths.

## D7 — In-BEAM triggers & approval park-and-resume

- **Decision**: `AgentOS.TriggerBus` (GenServer) accepts `{:event, name, payload}` and
  `{:message, payload}` casts and fires a run via the existing `RunSupervisor.start_run/1`,
  passing `trigger: :event | :message`. The daily `Scheduler` becomes one trigger source among
  these. Approval is an event-trigger: when the gate marks an action `requires_approval`,
  `run_worker` parks it as a `PendingApproval` in a `StateStore` mount and completes the run; an
  approval event (`{:event, {:approval, ref}, …}`) drives the parked action through the gate +
  effector. Manifest `triggers:` gains `type: event` / `type: message`.
- **Rationale**: Constitution IX — agents are invocation-scoped; "looping is a trigger
  re-invoking them." Triggers as substrate messages and approval as park-and-resume avoid any
  long-lived waiting process and reuse the single-writer store for pending state. In-BEAM (no
  web/CLI) is the simplest transport (clarify answer, Principle I).
- **Alternatives rejected**: Block-until-approved (rejected in clarify — holds a process open);
  external HTTP ingress (deferred — adds a network surface this phase doesn't need).

## D8 — World-B adversarial test strategy

- **Decision**: Two layers. (1) **Unit-level** `gate_test.exs` feeds the gate hostile proposed
  actions — out-of-scope recipient, ungranted method/connector, over-cap cost — and asserts each
  is `:reject`/`:breach` and the effector is never called (deterministic, primary proof). (2)
  **Full-stack** `world_b_test.exs` (`:docker`) runs `agents/discovery/adversarial_stub.py`, a
  hostile agent image that emits those same proposals, and asserts the gate blocks all three end
  to end with the effector never executing.
- **Rationale**: SC-008/FR-017 — world B must be proven by an adversary, not a cooperative run.
  The unit layer gives fast deterministic coverage of every reject branch; the docker layer
  proves it holds across the real boundary with real agent code that *tries* to breach.
- **Alternatives rejected**: Only inspecting a well-behaved run (proves nothing); only a docker
  test (slow, harder to assert each branch, gated behind Docker availability).

## D9 — Connector capability registry (intrinsic danger vs author scope)

- **Decision**: Introduce a substrate-side **connector capability registry** (`AgentOS.Connector`
  behaviour + a registry of entries). Each connector is a **generic capability** with intrinsic
  metadata: `%{mutating?, requires_approval?, credential, cost}`. Connector names are generic
  (`kv_append`, `external_send`), never agent verbs. The manifest grant references a connector by
  name and adds only per-agent scope (`recipients`, `methods`). The gate and meter read approval,
  credential, and cost from the registry; the manifest cannot set them.
- **Rationale**: Approval/credential/cost are properties of *a capability*, not author choices.
  Putting them in the manifest lets the author downgrade danger — fatal once a machine authors
  manifests (v3). The registry makes danger non-negotiable by the author (the soundness core of
  "enforcement earned on easy mode before generation", Principle XII). It also **de-leaks** the
  current `Effector`, which hard-codes `"record_signal"`/`"append_digest"` (a Principle IX
  violation today): the effector will dispatch by connector generically via the registry.
- **Mapping**: existing actions become registry connectors — local state writes → `kv_append`
  (`mutating? true`, `requires_approval? false`, `credential nil`, low `cost`); the new
  credentialed demo action → `external_send` (`requires_approval? true`, `credential
  :outbound_token`). The stub agent emits actions typed by connector; its domain vocabulary
  (digest/roster) stays in the payload, never the action type.
- **Alternatives rejected**: per-grant `requires_approval`/`cost` (unsound, see D2). A static map
  keyed by the agent's concrete verbs — a Principle IX leak; the registry is keyed by generic
  capability names instead.
- **Deferred refinement**: "escalate-only" — letting a manifest *add* approval to a connector
  that doesn't require it by default, but never *remove* it. v2 treats approval as purely
  intrinsic (registry decides); the monotonic-escalation rule is a later nicety, not needed now.

## Open implementation-level items (for /speckit-tasks, not blocking)

- Exact run-log schema additions for gate rejections and breach kills (a `gate`/`killed` field).
- Whether `OutputCheck` is deleted outright or kept as `Gate`'s first-stage shape check (lean
  toward folding it in to avoid a vestigial module).
- Concrete mock-connector action name in the manifest (a neutral, agent-agnostic name).
