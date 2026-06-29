# Phase 0 — Research: Credential Proxy

All decisions favour the simplest thing that makes the credential unreachable to the agent
(Constitution I), reuse existing substrate shapes, and keep tests deterministic with no live
dependency (Constitution IV).

## R1 — How to hold a secret and hand it out without ever returning or logging it

**Decision**: A single-writer `GenServer` holds an in-memory map `%{credential_id => secret}`.
The only public access path is `with_credential(credential_id, fun)`: the GenServer resolves the
secret and runs `fun.(secret)` such that the *only* value crossing back to the caller is
`fun`'s result. The secret is never a reply payload, never a return value, never interpolated
into a log line.

**Where `fun` runs**: `fun` is applied in the **caller** process, not inside the GenServer.
`with_credential/2` does a `GenServer.call` to fetch the secret into the caller, applies `fun`,
and the public function returns only `fun`'s result; the fetched secret goes out of scope.
Rationale: running arbitrary caller closures inside the single-writer GenServer would block the
mailbox and risk a crash taking down the holder. The secret does momentarily live in the caller
(the effector, a non-LLM control-plane component) — which is correct: Principle XI forbids an
**LLM-running** component from holding a mutating credential; the deterministic effector is
exactly where injection is supposed to happen. The agent (the LLM workload across the port) never
calls the proxy and never receives the secret.

**Never-logged discipline**: error paths log the *credential id* and a reason, never the secret
value. A raised closure propagates normally; we do not catch-and-log the secret. The proxy holds
no secret in any struct that gets inspected/printed by `RunLog` or `Inventory` (it is a separate
process with no persistence).

**Alternatives considered**:
- *Return the secret from a `fetch/1` call* — rejected: the secret would be a return value (and
  thus eligible to be bound, logged, traced); violates FR-002/FR-007 by construction.
- *Apply `fun` inside the GenServer* — rejected: blocks the single writer and couples holder
  liveness to caller code; no security benefit since the effector is non-LLM anyway.
- *`:persistent_term` / ETS table* — rejected: wider read surface, easy to dump; a GenServer with
  a private map is the tighter, simpler holder and matches `StateStore`'s established shape.

## R2 — Where credentials come from and how tests seed them deterministically

**Decision**: The proxy loads its map at `init/1` from `Application.get_env(:agent_os, :credentials, %{})`.
In `config/config.exs`, real entries source from the OS env at config time
(`System.get_env("OUTBOUND_TOKEN")`), so no secret is committed. The `:test` block seeds
deterministic values: one **mutating** credential (`:outbound_token`) and one **inference-only**
credential (a read-only model key) held under a **distinct** key, so the separation requirement
(FR-008) is provable without any live secret (Constitution IV).

**Rationale**: mirrors how the rest of the substrate is configured (hard-wired app env in
`config.exs`, test env overrides); keeps secrets out of the repo; gives tests a known value to
assert injection and absence against.

**Alternatives considered**: reading OS env directly in the effector at action time — rejected:
spreads secret access beyond the single holder and defeats the "one process holds capabilities"
design.

## R3 — The exact effector injection seam

**Decision**: In `Effector.act/1`, the `external_send` branch:
1. looks up the action's connector in `AgentOS.Connector.registry()` (the gate already validated
   it; the effector re-reads the registry for the connector's intrinsic `credential`);
2. if `credential == nil` → run the sink directly, never contacting the proxy (FR-005);
3. if `credential` is an id → `CredentialProxy.with_credential(id, fn secret -> sink(payload, secret) end)`,
   injecting at the sink call site only (FR-004);
4. if the proxy cannot resolve the id → `with_credential/2` returns `{:error, {:unknown_credential, id}}`;
   the effector returns that error and the sink does **not** run (FR-009, fail closed).

`act_all/1` already maps `act/1` over approved actions, so no change to the run-worker call site
is needed. The connector is found via the action `type` (the registry is keyed by connector
name, which is the action type — consistent with the existing `kv_append`/`external_send` mapping
and `get_cost/2` in `run_worker.ex`).

**Rationale**: the seam already exists and is stubbed for precisely this (`effector.ex` external_send
no-op note). Keeping the registry lookup in the effector (not the gate) respects Principle X —
intrinsic danger/credential is fixed by the registry, read at the deterministic chokepoint.

**Alternatives considered**: passing the credential through the gate's approved-action map —
rejected: would put the secret (or its id resolution) on the gate path and risk it reaching the
trace; the effector is the correct, narrowest injection point.

## R4 — Extending the 003 boundary invariant to the credential value

**Decision**: Add an assertion to the existing `test/agent_os/boundary_test.exs`: with the proxy
started and seeded with the known test mutating credential, construct the real agent-bound payload
and container env and assert the **secret value** is absent from both. This extends 003's
credential-*reference* absence to the credential *value* via the real proxy, satisfying
acceptance scenario 3 and FR-006 without reconstructing the boundary.

**Rationale**: keeps a single honest boundary test that tracks the real code paths (003's
principle) and now also pins the concrete secret value.

**Alternatives considered**: a separate credential-only boundary test — rejected: duplicates the
003 surface enumeration; one boundary test that asserts the full envelope + the credential value
is simpler and harder to let rot.

## Summary of resolved unknowns

| Unknown | Resolution |
|---|---|
| Secret never returned/logged | `with_credential/2` returns only the closure result; errors log the id, never the value; no persistence (R1) |
| Where `fun` executes | In the caller (effector), not the GenServer; agent never calls the proxy (R1) |
| Credential source + test seeding | App env sourcing OS env; `:test` seeds a mutating + a distinct inference-only credential (R2) |
| Effector seam + fail-closed | registry lookup → nil bypasses proxy, id ⇒ with_credential, unresolvable ⇒ {:error,…}, sink never runs (R3) |
| Boundary value assertion | extend 003 boundary_test to assert the secret value absent via the real proxy (R4) |
