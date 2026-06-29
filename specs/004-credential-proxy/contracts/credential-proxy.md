# Contract — Credential Proxy & Effector Injection

Two contracts: the proxy's public API, and the effector's use of it at the chokepoint. Both are
internal Elixir module contracts (no external interface; control-plane only).

## Contract A — `AgentOS.CredentialProxy`

A single-writer GenServer holding secrets keyed by registry credential id, in memory.

### `with_credential(credential_id, fun)`

```
@spec with_credential(credential_id :: atom(), fun :: (String.t() -> result)) ::
        result | {:error, {:unknown_credential, atom()}}
      when result: var
```

- **Resolves** the secret stored under `credential_id`.
- **On hit**: applies `fun.(secret)` and returns **only `fun`'s result**. The secret is never the
  return value, never logged, never persisted. (FR-002, FR-007, SC-003)
- **On miss** (id not loaded): returns `{:error, {:unknown_credential, credential_id}}`, logs the
  id and reason (never a secret), and does **not** call `fun`. (FR-009)
- The secret is in scope only inside `fun`. (FR-006, FR-007)

### Lifecycle

- `start_link/1` and `child_spec/1` in the supervision tree (mirrors `StateStore` shape). (FR-003)
- `init/1` loads `Application.get_env(:agent_os, :credentials, %{})` into memory. (FR-001)
- Holds nothing on disk; mutating and inference-only secrets under distinct keys, exact-id
  resolution, no default fallback. (FR-008, INV-3, INV-4)

### Contract tests (`test/agent_os/credential_proxy_test.exs`)

| # | Given | When | Then | FR/SC |
|---|---|---|---|---|
| A1 | proxy seeded with `:outbound_token => "tok"` | `with_credential(:outbound_token, fn s -> String.length(s) end)` | returns `3`; the secret string is not the return value | FR-002, SC-003 |
| A2 | same | `with_credential(:outbound_token, fn s -> s end)` captured | the only way to see the secret is to deliberately return it from the fun; no proxy call yields it otherwise | SC-003 |
| A3 | proxy seeded | a `with_credential` call that succeeds | nothing is logged containing the secret value (capture log) | FR-007, SC-002 |
| A4 | proxy with no `:nope` key | `with_credential(:nope, fun)` | `{:error, {:unknown_credential, :nope}}`; `fun` not called | FR-009, SC-004 |
| A5 | proxy seeded with mutating `:outbound_token` + inference-only `:model_key` | resolve each | distinct values; `:model_key` never served for `:outbound_token` and vice versa | FR-008, SC-005 |
| A6 | proxy seeded | `with_credential(:outbound_token, fn _ -> raise "boom" end)` | the exception propagates; the secret value is in neither the captured log nor the exception/stack trace; the proxy does not return the secret in any error | FR-007 (spec Edge Case "Closure raises") |

## Contract B — Effector injection at the chokepoint

`AgentOS.Effector.act/1` for an `external_send` action, post-gate-approval.

```
act(%{action: %ProposedAction{type: "external_send"} = action, grant: _}) :: :ok | {:error, term()}
```

- Looks up the connector for `action.type` in `AgentOS.Connector.registry()`.
- `credential == nil` → runs the sink directly; the proxy is **not** contacted. (FR-005)
- `credential == id` → `CredentialProxy.with_credential(id, fn secret -> <mock sink>(action, secret) end)`;
  the sink records the delivered payload and runs only because the secret was injected. (FR-004, FR-010)
- proxy returns `{:error, {:unknown_credential, id}}` → effector returns the error; **sink does not
  run; no payload recorded**. (FR-009)

### Contract tests (`test/agent_os/effector_test.exs`)

| # | Given | When | Then | FR/SC |
|---|---|---|---|---|
| B1 | proxy seeded with `:outbound_token`; mock sink observable | `act` an approved `external_send` | sink records the delivered payload; `:ok` | FR-004, FR-010, SC-001 |
| B2 | as B1 | after `act` | the secret value is absent from the returned value, captured logs, and (via run pipeline) the run-trace and inventory | FR-007, SC-002 |
| B3 | `kv_append` approved action | `act` it | state appended as before; proxy never called | FR-005, SC-005 |
| B4 | proxy with **no** `:outbound_token` loaded | `act` an approved `external_send` | `{:error, {:unknown_credential, :outbound_token}}`; mock sink recorded nothing | FR-009, SC-004 |

## Contract C — Boundary value (extends 003)

In `test/agent_os/boundary_test.exs`, with the proxy started and seeded with the known test
mutating credential:

| # | Given | When | Then | FR/SC |
|---|---|---|---|---|
| C1 | proxy holds `:outbound_token => "tok"` | construct the real agent-bound payload + container env | the secret value `"tok"` appears in neither the payload nor the env | FR-006, SC-001 |
