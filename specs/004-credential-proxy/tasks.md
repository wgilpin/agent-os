---
description: "Task list for Credential Proxy (spec 004, roadmap plan 03-03)"
---

# Tasks: Credential Proxy

**Input**: Design documents from `specs/004-credential-proxy/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/credential-proxy.md, quickstart.md

**Tests**: INCLUDED. The spec is test-driven (Constitution III — TDD backend; Constitution IV —
no live deps) and the contracts define explicit test tables. Tests are written red-first.

**Organization**: One user story (US1, P1). Setup → Foundational → US1 → Polish.

**Branch note**: Work lands on `master` (002/003 convention). The spec dir, not the branch, is the
source of truth (`.specify/feature.json`).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1 (the sole user story)

## Path Conventions

Single project — BEAM control plane. Production code in `lib/agent_os/`, tests in
`test/agent_os/`, config in `config/config.exs`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Make credentials available to the substrate without committing secrets.

- [x] T001 Add a `:credentials` map to `config :agent_os` in `config/config.exs`, sourcing real values from OS env at config time (e.g. `outbound_token: System.get_env("OUTBOUND_TOKEN")`); document with a comment that secrets come from OS env, never the repo (FR-001, research R2)
- [x] T002 In the `config_env() == :test` block of `config/config.exs`, seed deterministic test credentials: a mutating `:outbound_token` and a distinct inference-only key (e.g. `:model_key`), so injection and separation are provable with no live secret (FR-008, Constitution IV)

**Checkpoint**: Credentials are configurable; tests have known values to assert against.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: None beyond Setup. This feature is a single story; the proxy module itself is part of
US1. No separate foundational layer is required.

**Checkpoint**: Proceed to US1.

---

## Phase 3: User Story 1 - A credentialed action runs only via chokepoint injection (Priority: P1) 🎯 MVP

**Goal**: A gate-approved credentialed action executes only because the proxy injects the secret at
the effector chokepoint; the agent never holds a mutating credential; non-credentialed actions skip
the proxy; an unresolvable credential id fails closed.

**Independent Test**: Drive an approved `external_send` through `AgentOS.Effector.act/1` with the
proxy seeded — the mock sink records the payload; the secret is absent from the return value, logs,
run-trace, inventory, agent env, and boundary payload; `kv_append` never touches the proxy; a
missing credential id yields `{:error, {:unknown_credential, …}}` and the sink records nothing.

### Tests for User Story 1 (write FIRST, ensure they FAIL before implementation) ⚠️

- [x] T003 [P] [US1] Write `AgentOS.CredentialProxy` contract tests in `test/agent_os/credential_proxy_test.exs` per contract A (A1–A6): `with_credential/2` returns only the closure result; the secret is never a return value of any other public call; nothing logged contains the secret (use `ExUnit.CaptureLog`); unknown id → `{:error, {:unknown_credential, id}}` and `fun` not called; mutating vs inference-only held under distinct keys with exact-id resolution; **A6 — closure raises**: `with_credential(:outbound_token, fn _ -> raise "boom" end)` lets the exception propagate and the secret value appears in neither the captured log nor the exception/stack trace (spec Edge Case "Closure raises") (FR-002, FR-007, FR-008, FR-009; SC-002, SC-003, SC-004, SC-005)
- [x] T004 [P] [US1] Write effector injection tests in `test/agent_os/effector_test.exs` per contract B (B1–B4): approved `external_send` injects at the chokepoint and the mock sink records the delivered payload; the secret is absent from the return value and captured logs; `kv_append` never contacts the proxy; an unresolvable id fails closed with no payload recorded (FR-004, FR-005, FR-009, FR-010; SC-001, SC-004, SC-005)
- [x] T005 [US1] Extend `test/agent_os/boundary_test.exs` per contract C (C1): with the proxy started and seeded with the known mutating credential, assert the secret **value** is absent from the real agent-bound payload and the container env (FR-006; SC-001)

### Implementation for User Story 1

- [x] T006 [US1] Implement `AgentOS.CredentialProxy` in `lib/agent_os/credential_proxy.ex`: single-writer GenServer mirroring `AgentOS.StateStore`'s `child_spec/1` + `start_link/1`; `init/1` loads `Application.get_env(:agent_os, :credentials, %{})` into an in-memory map (no persistence); `with_credential(credential_id, fun)` fetches the secret via `GenServer.call`, applies `fun` in the caller, returns only `fun`'s result, and returns `{:error, {:unknown_credential, id}}` + a `Logger` error (id only, never the secret) on a miss; `@moduledoc` states the Principle XI invariant (FR-001, FR-002, FR-003, FR-007, FR-009, FR-011) — makes T003 green
- [x] T007 [US1] Add `AgentOS.CredentialProxy` to the supervision tree in `lib/agent_os/application.ex` (in the `autostart` children list, alongside the `StateStore` instances) (FR-003)
- [x] T008 [US1] Implement the `external_send` mock sink body in `lib/agent_os/connector.ex`: runs only when an injected credential is supplied, then records the delivered payload by sending `{:external_send, payload}` to the pid in `Application.get_env(:agent_os, :external_send_sink_pid)` (defaults to inert/no-op when unset); each test sets that pid to its own process in `setup` via `Application.put_env(:agent_os, :external_send_sink_pid, self())` (with an `on_exit` `delete_env`) so `assert_receive {:external_send, payload}` observes the delivery — no live external service/LLM/Docker (FR-010, Constitution I/IV)
- [x] T009 [US1] Wire injection into `lib/agent_os/effector.ex`: replace the `external_send` no-op so it looks up the connector for `action.type` in `AgentOS.Connector.registry()`; if `credential == nil` run the sink directly (no proxy contact); if `credential` is an id call `CredentialProxy.with_credential(id, fn secret -> sink(action, secret) end)`; on `{:error, {:unknown_credential, id}}` do NOT run the sink and `Logger.error` the fail-closed event (connector + id only, never the secret) so it is loud and legible (Principle VI/VIII), then return the error; update the module note to state injection occurs only post-approval at the chokepoint (FR-004, FR-005, FR-009, FR-011) — makes T004 green
- [x] T010 [US1] Run T003–T005 and confirm green; verify (a) the secret value appears in 0 run-trace and 0 inventory entries across a full run pipeline (SC-002) and (b) a fail-closed `external_send` is observable — the effector's `Logger.error` fires (id only) — even though `act_all/1` discards per-action results; record the `act_all/1` swallow as a known limitation note in the effector (batch error aggregation is out of scope for 004, deferred) (FR-009, Principle VIII)

**Checkpoint**: US1 fully functional and independently testable — credentialed action runs via
chokepoint injection; no mutating credential anywhere the agent can read; fail-closed on miss.

---

## Phase 4: Polish & Cross-Cutting Concerns

**Purpose**: Gates clean and the guarantee documented/verified.

- [x] T011 [P] Run `mix format --check-formatted` and `mix credo` clean across changed files (Constitution Quality Gates)
- [x] T012 [P] Run `mix dialyzer` clean — confirm `with_credential/2` typespec and reused `Connector.capability()` / `ProposedAction` / `Grant` types check (Constitution V)
- [x] T013 Run the full `mix test` suite green (fix any pre-existing failures encountered — global rule: no unaddressed failures)
- [x] T014 Walk `specs/004-credential-proxy/quickstart.md` end to end to confirm the six by-hand checks pass (SC-001…SC-006)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately. T001 and T002 edit the same file (`config.exs`); do them in order, not in parallel.
- **Foundational (Phase 2)**: empty — nothing to do.
- **User Story 1 (Phase 3)**: depends on Setup (tests need seeded test credentials from T002).
- **Polish (Phase 4)**: depends on US1 complete.

### Within User Story 1

- TDD: T003, T004, T005 (tests, red) **before** T006–T009 (implementation, green).
- T006 (proxy) before T007 (supervision) and before T009 (effector calls the proxy).
- T008 (mock sink) before/with T009 (effector calls the sink); both before T010 (full-pipeline check).
- T010 last in the story (verifies trace/inventory cleanliness after everything is wired).

### Parallel Opportunities

- **Setup**: T001 → T002 sequential (same file).
- **US1 tests**: T003 and T004 are different files → `[P]`. T005 edits the existing `boundary_test.exs` and can also run alongside (different file) but depends on the proxy being startable for assertion C1 — run it after T006/T007 or stub the proxy start in the test setup.
- **US1 impl**: T006 and T008 touch different files and can be drafted in parallel; T007 and T009 depend on T006.
- **Polish**: T011 and T012 are independent `[P]`.

---

## Parallel Example: User Story 1 tests

```bash
# Write the two independent test files red-first, in parallel:
Task: "Write CredentialProxy contract tests in test/agent_os/credential_proxy_test.exs"   # T003
Task: "Write effector injection tests in test/agent_os/effector_test.exs"                  # T004
```

---

## Implementation Strategy

### MVP (this whole feature is the MVP)

1. Phase 1 Setup → credentials configurable + seeded for tests.
2. Phase 3 US1 tests red → implement proxy → wire supervision → mock sink → effector injection → green.
3. **STOP and VALIDATE**: the independent test above; confirm secret absent from every agent-reachable
   surface, log, trace, and inventory; confirm fail-closed.
4. Phase 4 Polish → gates clean, quickstart walked.

### Notes

- [P] = different files, no incomplete dependency.
- This feature realizes Constitution Principle XI; keep the `@moduledoc`/effector notes that say so.
- Per repo rules: do not commit automatically; leave changes in the working tree for the user.
- No Docker / live LLM / external service in any test (Constitution IV); the `external_send` sink is a mock.
