# Contract: Port Boundary — the manifest never crosses

This contract asserts an **invariant**, not a new interface. The port-boundary payload is
unchanged from earlier phases; the point of this feature is to prove and protect that the
enforcement envelope never reaches any agent-reachable surface (FR-001…FR-007, SC-001…SC-005).

## Substrate → agent (across the port)

The only payload sent into the container:

```json
{
  "state": { "records": [ ... ] },
  "items": [ { /* sanitized bookmark item */ } ]
}
```

Plus the published **action schema** the agent emits against (the shape of a proposed action:
`type`, optional `recipient`, optional `method`, `payload`).

**Top-level shape MUST be exactly** `{state, items}`. A new top-level key is a deliberate
contract change that updates this document and the invariant test in the same change.

**MUST NOT appear anywhere in the payload, the container mount set, or the agent env**:
`grants`, `recipients`, `methods`, `cost`, `requires_approval`, `spend`, `cap`, `window`,
`on_breach`, the configured grant/recipient/method/spend values from the manifest, or any
credential/secret (e.g. `outbound_token`).

## agent → substrate (across the port)

```json
{ "actions": [ { "type": "...", "recipient": "...", "method": "...", "payload": { ... } } ] }
```

Unchanged in shape; `recipient`/`method` are agent-supplied and untrusted, evaluated by the gate.

## Container surfaces

| Surface | Producer | Invariant |
|---------|----------|-----------|
| Payload | `RunWorker` (JSON over the port) | only `{state, items}` + action schema |
| Mount set | `Sandbox.build_argv/1` | no bind mount (`-v`/`--volume`); never the manifest path |
| Environment | `Sandbox` env → `docker run -e` | no mutating credential |

## Verification (test, not new runtime code)

A contract test (`test/agent_os/boundary_test.exs`) asserts, against the **real** producers:

1. The serialized substrate→agent payload's top-level keys are exactly `["items", "state"]`
   and it contains none of the envelope keys, none of the configured envelope values (read from
   the loaded manifest), and no credential id.
2. `Sandbox.build_argv/1` output contains no bind-mount flag and no element referencing the
   manifest path/file.
3. `Sandbox.build_argv/1` output (env args) contains no mutating credential value.
4. **Anti-vacuousness**: the loaded manifest genuinely carries non-empty grants and a spend cap,
   so the absence assertions are meaningful.

These guard against regression of an invariant the current architecture already satisfies. The
substrate also carries a discoverable statement of the invariant in the `@moduledoc` of
`run_worker.ex` and `manifest.ex`.
