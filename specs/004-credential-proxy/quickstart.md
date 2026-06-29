# Quickstart — Credential Proxy

How to run and confirm the feature once implemented. Everything is deterministic — no Docker, no
live LLM, no external service (Constitution IV).

## Run the tests

```sh
# the three touch-points for this feature
mix test test/agent_os/credential_proxy_test.exs \
         test/agent_os/effector_test.exs \
         test/agent_os/boundary_test.exs

# full suite + gates (must be clean before save)
mix test
mix format --check-formatted
mix credo
mix dialyzer
```

## Confirm the structural guarantee by hand

1. **Injection happens at the chokepoint.** Start the proxy seeded with the test
   `:outbound_token`, drive an approved `external_send` through `AgentOS.Effector.act/1`, and see
   the mock sink record the delivered payload. The sink ran **only** because the secret was
   injected inside the `with_credential` closure.

2. **The secret never leaves the closure.** Confirm `with_credential(:outbound_token, fun)` returns
   only `fun`'s result — there is no public proxy call that hands back the secret itself.

3. **The agent can't see it.** The boundary test (extends 003) asserts the secret value is absent
   from the agent-bound payload and the container env. The agent never calls the proxy.

4. **Nothing leaks to the trace.** After a run, inspect the run-log and inventory — the secret
   value appears in zero entries and zero log lines.

5. **Non-credentialed actions skip the proxy.** Drive an approved `kv_append`; it appends state as
   before and the proxy is never contacted.

6. **It fails closed.** Start the proxy with **no** `:outbound_token` loaded, drive an approved
   `external_send`, and confirm you get `{:error, {:unknown_credential, :outbound_token}}` and the
   mock sink recorded nothing.

## What "done" looks like

- `AgentOS.CredentialProxy` is in the supervision tree, holding secrets from app/OS env in memory.
- `Effector.act/1` injects the credential for credentialed connectors at the sink call site only,
  post-approval; non-credentialed connectors never touch the proxy; unresolvable ids fail closed.
- The `external_send` mock sink records its delivered payload and runs only with an injected secret.
- The secret value is absent from the agent surface, logs, run-trace, and inventory — proven by test.
- `@moduledoc`/effector notes state the Principle XI invariant.
