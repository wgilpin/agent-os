# Phase 1 — Data Model: Credential Proxy

No persisted entities. The only new "data" is the in-memory secret map held by the proxy process
and the link from the connector registry to it. Listed here as conceptual entities with their
fields, invariants, and the FRs they satisfy.

## Entity: Credential Proxy state

The in-memory state of the `AgentOS.CredentialProxy` GenServer.

| Field | Type | Notes |
|---|---|---|
| `credentials` | `%{credential_id => secret}` | `credential_id :: atom()` (matches the registry's `credential` field); `secret :: String.t()`. Held in memory only — never persisted, never in a struct that is logged/traced. |

**Invariants**
- INV-1: The map is loaded once at `init/1` from `Application.get_env(:agent_os, :credentials, %{})`. (FR-001)
- INV-2: No public call returns a value from `credentials`; the secret is only ever passed to a caller-supplied function. (FR-002, SC-003)
- INV-3: The state is never written to disk, the run-trace, or the inventory. (FR-007, SC-002)
- INV-4: Mutating and inference-only secrets occupy distinct keys; resolution is by exact id, with no fallback/default. (FR-008, FR-009)

## Entity: Credential kind (conceptual)

Distinguishes what a held secret authorizes. Not a stored field — encoded by *which key* holds it.

| Kind | Example key | Authorizes |
|---|---|---|
| Mutating | `:outbound_token` | An outbound/state-changing connector action (`external_send`). Must never reach an LLM-running component. |
| Inference-only | e.g. `:model_key` | Read-only model inference. Held separately; never served for a mutating action. (FR-008) |

**Validation**: A request for a connector's `credential` id resolves only to the secret stored
under that exact id. An inference-only key is never returned in place of a missing mutating one.

## Entity: Capability credential id (existing — from spec 002)

The `credential` field on a connector capability in `AgentOS.Connector` registry. The key that
ties a connector to the secret the proxy injects.

| Connector | `credential` | Behaviour at effector |
|---|---|---|
| `kv_append` | `nil` | No proxy contact; action runs unchanged. (FR-005) |
| `external_send` | `:outbound_token` | Effector wraps the sink in `with_credential(:outbound_token, fun)`. (FR-004) |

Unchanged by this feature — consumed, not redefined.

## Entity: Injection seam (effector chokepoint)

The single point where a credential enters an action's execution. Conceptual; realized in
`Effector.act/1`'s `external_send` branch.

**Flow**
1. Gate approves the action (upstream, unchanged).
2. Effector looks up the connector by action `type` in the registry.
3. `credential == nil` → run sink directly (no secret involved). (FR-005)
4. `credential == id` → `CredentialProxy.with_credential(id, fn secret -> sink(payload, secret) end)`. (FR-004)
5. proxy cannot resolve `id` → `{:error, {:unknown_credential, id}}`; sink does not run; no side effect. (FR-009)

**Invariants**
- INV-5: Injection occurs only after gate approval and only here. (FR-004, Principle XI)
- INV-6: The secret is in scope only inside `fun` during step 4; it is never bound into the
  approved-action map, the `RunLog` entry, or the inventory. (FR-006, FR-007)

## Entity: Mock sink (`external_send`)

A test-observable connector body standing in for a live external service (Constitution IV).

| Aspect | Definition |
|---|---|
| Input | the action payload + the injected `secret` |
| Effect | records the delivered payload by sending `{:external_send, payload}` to the pid in `Application.get_env(:agent_os, :external_send_sink_pid)` (inert when unset); tests set it to `self()` in `setup` and observe via `assert_receive` |
| Precondition | runs only when a credential has been injected (FR-010) |
| Live deps | none — no external service, no LLM, no Docker |

## FR coverage map

| FR | Entity / invariant |
|---|---|
| FR-001 | Credential Proxy state; INV-1 |
| FR-002 | INV-2 |
| FR-003 | Proxy is a single-writer GenServer in the supervision tree (see plan structure) |
| FR-004 | Injection seam steps 2–4; INV-5 |
| FR-005 | Injection seam step 3; Capability credential id (`kv_append`) |
| FR-006 | INV-6; extended 003 boundary assertion |
| FR-007 | INV-3, INV-6 |
| FR-008 | Credential kind; INV-4 |
| FR-009 | Injection seam step 5; INV-4 |
| FR-010 | Mock sink entity |
| FR-011 | `@moduledoc`/effector note (Principle XI statement) — see contracts |
