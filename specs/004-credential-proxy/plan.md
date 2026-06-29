# Implementation Plan: Credential Proxy

**Branch**: `004-credential-proxy` (work lands on `master`, per 002/003 convention) | **Date**: 2026-06-29 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/004-credential-proxy/spec.md`

## Summary

Make Constitution Principle XI structurally true: no LLM-running component holds a mutating
credential, so a compromised agent cannot act even if it bypassed the gate. Add a
single-writer `AgentOS.CredentialProxy` GenServer to the supervision tree that holds secrets
keyed by the connector registry's `credential` id (loaded from app/OS env) and exposes
`with_credential(credential_id, fun)` — the secret is only ever handed to a caller-supplied
closure, never returned. Wire it into the one existing seam that already awaits it: the
`external_send` branch of `AgentOS.Effector.act/1`, which today no-ops with the literal note
*"Credential proxy injection is wired in US3 (Phase 5)."* The effector, after the gate has
approved an action, looks up the action's connector in the registry; if it declares a
`credential`, the effector obtains the secret from the proxy and injects it at the sink call
site (a test-observable mock sink) and nowhere else. Non-credentialed connectors (e.g.
`kv_append`) never contact the proxy. An unresolvable credential id fails closed.

This was tracked as User Story 3 within 002-manifest-enforcement; it is carved into its own
spec/plan so the structural guarantee is delivered and tested as a dedicated unit, the way
US2 became 003-manifest-invisibility.

## Technical Context

**Language/Version**: Elixir ~> 1.20 (control plane only). No Python change.
**Primary Dependencies**: existing only — OTP `GenServer`, `Registry`, `Application` config.
No new deps. No Jason/YamlElixir change.
**Storage**: N/A — the proxy holds secrets **in memory only**, loaded at `init/1` from
application env (which sources from OS env). Nothing is persisted: no term-file, no git-backed
markdown. This is the one substrate-owned process that deliberately owns no on-disk state.
**Testing**: ExUnit. New: `test/agent_os/credential_proxy_test.exs` (proxy contract) and
effector credential-injection tests in `test/agent_os/effector_test.exs`; plus an assertion
added to the existing `test/agent_os/boundary_test.exs` (003) confirming the mutating
credential is absent from the agent surface using the real proxy. Pure and deterministic — no
Docker, no live LLM, no live external service (Constitution IV); the `external_send` sink is a
mock that records its delivered payload.
**Target Platform**: Linux/macOS host (unchanged).
**Project Type**: Single project — BEAM control plane + Python agent workload across a port
boundary (unchanged). This feature is control-plane only.
**Performance Goals**: N/A — credential lookup is an in-memory `GenServer.call` on the
post-approval path, off any hot loop (once per credentialed approved action).
**Constraints**: The secret MUST NOT be the return value of any public proxy call, MUST NOT be
logged (Constitution VI loud-failures must still avoid logging the secret value), and MUST NOT
be written to the run-trace (`RunLog`) or inventory. Injection happens only at action time,
only after gate approval, only at the effector chokepoint. Fail closed on an unresolvable id.
**Scale/Scope**: One proxy process; two seeded credential kinds (one mutating
`:outbound_token`, one inference-only key held under a distinct key to prove separation). One
new module + supervision-tree entry + effector wiring + mock sink body. ~1 module of
production code, three test touch-points.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Simplicity First | PASS | One GenServer holding an in-memory map + one effector branch + a mock sink. No new deps, no persistence, no abstraction beyond `with_credential/2`. The simplest thing that makes the credential unreachable to the agent. |
| II. Explicit Scope Control | PASS | Exactly US3 from the 002 roadmap. No spend (03-04), no triggers (03-05), no world-B (03-06), no gate-logic change (03-01). Out-of-scope fenced in spec. |
| III. Test-Driven Backend | PASS | Proxy contract test and effector injection test written red-first; the mock sink lets us assert injection deterministically. |
| IV. No Live Dependencies in Tests | PASS | `external_send` is a mock sink recording its payload; no Docker, no LLM, no remote call. Secret comes from test config. |
| V. Strong Typing, No Bare Maps | PASS | `with_credential/2` typed; the proxy state is a typed map keyed by credential-id atom; reuses the existing `Connector.capability()` type and `ProposedAction`/`Grant` structs. Dialyzer clean. |
| VI. Loud Failures | PASS | Unresolvable credential id → logged error (id only, never a secret) + fail-closed `{:error, …}`; closure raise propagates without leaking the secret. No silent swallow. |
| VII. Self-Documenting Comments | PASS | `@moduledoc` on `CredentialProxy` and updated effector note state the Principle XI invariant (no LLM component holds a mutating credential; injection only post-approval at the chokepoint) — FR-011. |
| VIII. Legibility | PASS | The credential boundary becomes a named, inspectable process; the run-trace/inventory remain readable without the agent and provably free of the secret. |
| IX. Substrate Owns State & Lifecycle (agent-agnostic) | PASS | The proxy is a substrate-owned single-writer process. Credential ids are generic capability keys from the registry (`:outbound_token`), not any agent's domain vocabulary — no leak into `lib/`. |
| X. No Ambient Authority | PASS | The agent's power remains exactly its manifest grants; it never gains the *means* to act. The proxy holds the capability; the holder (agent) cannot widen its authority. |
| XI. The Gate Is the Only Firewall | PASS | **This feature is the realization of XI**: no component that runs an LLM holds a mutating credential; privileged action is deterministic, on the agent's behalf, only after the gate check, with the secret injected downstream of approval. |
| XII. Enforcement Precedes Generation | PASS | Pure v2 enforcement on hand-authored manifests; no generation. Strengthens the precondition v3 depends on. |

**No violations.** No Complexity Tracking entries required.

## Project Structure

### Documentation (this feature)

```text
specs/004-credential-proxy/
├── plan.md                  # This file
├── research.md              # Phase 0 — credential-holding patterns, leak-avoidance, fail-closed
├── data-model.md            # Phase 1 — proxy state, credential kinds, the injection seam
├── quickstart.md            # Phase 1 — run the tests; prove injection; prove the secret never leaks
├── contracts/
│   └── credential-proxy.md  # Phase 1 — the with_credential/2 contract + effector injection contract
├── checklists/
│   └── requirements.md      # Spec quality checklist (from /speckit-specify)
└── tasks.md                 # Phase 2 — created by /speckit-tasks, NOT here
```

### Source Code (repository root)

```text
lib/agent_os/
├── credential_proxy.ex      # NEW — single-writer GenServer; holds secrets keyed by registry credential id;
│                            #       with_credential(credential_id, fun) hands secret to closure, never returns it
├── effector.ex              # MODIFIED — external_send branch: look up connector; if it declares a credential,
│                            #            CredentialProxy.with_credential(id, fn secret -> sink end); fail closed on miss
├── connector.ex             # MODIFIED — external_send mock sink body (records delivered payload to a
│                            #            test-observable destination; runs only with an injected credential)
└── application.ex           # MODIFIED — add CredentialProxy to the supervision tree

config/
└── config.exs               # MODIFIED — :agent_os, :credentials map: credential-id => System.get_env(...);
                             #            test env seeds deterministic mutating + inference-only credentials

test/agent_os/
├── credential_proxy_test.exs # NEW — with_credential/2 contract: secret only inside the fun; never returned;
│                             #       never logged; mutating vs inference-only held under distinct keys; miss fails closed
├── effector_test.exs         # MODIFIED/NEW — credentialed external_send injects at chokepoint & sink records;
│                             #       kv_append never contacts proxy; unresolvable id fails closed, sink records nothing
└── boundary_test.exs         # MODIFIED — assert the mutating credential value is absent from the agent surface
                              #            (env + boundary payload) using the real proxy (extends 003)
```

**Structure Decision**: Single project, one new module. The proxy mirrors the established
single-writer-GenServer shape of `AgentOS.StateStore` (child_spec, `start_link`, `GenServer.call`)
but holds its map in memory and never persists. The injection seam is the existing
`Effector.act/1` `external_send` branch — already stubbed for this exact work — so the change is
localized: the effector gains a registry lookup and a `with_credential` wrap, and the connector
gains a real mock-sink body. No new authority crosses the port boundary.

## Phase 0 — Research

See [research.md](./research.md). Resolves: (1) how a BEAM process can hold a secret and hand it
to a closure such that the secret is never the return value and never appears in logs, the
run-trace, or the inventory — and what "never logged" demands of error handling; (2) where
credentials are loaded from (app env sourcing OS env at config time) and how the test env seeds a
deterministic mutating credential plus a distinct inference-only credential to prove separation
without a live secret; (3) the precise effector seam — look up the approved action's connector in
the registry, branch on `credential` (nil ⇒ no proxy contact; present ⇒ `with_credential`), and
fail closed on an unresolvable id; (4) how to extend the 003 boundary test to assert the credential
value's absence using the real proxy rather than a reconstruction.

## Phase 1 — Design & Contracts

- [data-model.md](./data-model.md) — the **Credential Proxy state** (id ⇒ secret, in memory),
  the **mutating vs inference-only** credential kinds, the **capability credential id** link from
  the registry, and the **injection seam** in the effector, with validation rules mapping to
  FR-001…FR-011.
- [contracts/credential-proxy.md](./contracts/credential-proxy.md) — the `with_credential/2`
  contract (secret in, closure result out, secret never returned/logged/persisted) and the
  effector-injection contract (credentialed ⇒ injected at sink; non-credentialed ⇒ untouched;
  unresolvable ⇒ fail closed, no side effect).
- [quickstart.md](./quickstart.md) — run the proxy + effector + boundary tests green; drive a
  credentialed `external_send` and see the mock sink record the payload; prove the secret is
  absent from the agent surface, logs, run-trace, and inventory; see an unresolvable id fail closed.

**Post-design Constitution re-check**: still PASS — the proxy is a substrate-owned single-writer
process holding generic capability-keyed secrets in memory; no agent vocabulary in `lib/`, no new
authority across the boundary, and the gate remains the sole firewall with the credential now
provably downstream of approval.
