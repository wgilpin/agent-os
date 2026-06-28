# Contract: Port Boundary (manifest does NOT cross)

This contract asserts an invariant rather than introducing a new interface. The port-boundary
payload is unchanged from Phase 2; the point of this phase's enforcement is that the **manifest
never crosses it** (FR-006/FR-007, US2, SC-003).

## Substrate → agent (across the port)

The only payload sent into the container, exactly as today:

```json
{
  "state": { "records": [ ... ] },
  "items": [ { /* sanitized bookmark item */ } ]
}
```

Plus the published **action schema** the agent emits against (the shape of a proposed action:
`type`, optional `recipient`, optional `method`, `payload`).

**MUST NOT appear anywhere in the payload or the container mount set**: `grants`, `recipients`,
`methods`, `cost`, `requires_approval`, `spend.cap`, `spend.window`, `spend.on_breach`, or any
credential/secret (FR-006, FR-009).

## agent → substrate (across the port)

```json
{ "actions": [ { "type": "...", "recipient": "...", "method": "...", "payload": { ... } } ] }
```

Unchanged in shape; `recipient`/`method` are now meaningful to the gate but are still
agent-supplied and untrusted.

## Verification (test, not new code)

- A contract test asserts the serialized boundary payload for a run contains none of the
  manifest's grant/constraint/spend keys nor any capability secret (SC-003, SC-004).
- A test asserts the container mount set (from `Sandbox.build_argv/1`) does not include the
  manifest path.
- The agent environment passed to the container contains no mutating credential (SC-004).

These guard against regression of an invariant the current architecture already satisfies (see
research D3).
