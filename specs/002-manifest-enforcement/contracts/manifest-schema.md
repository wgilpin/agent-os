# Contract: v2 Manifest Schema

The enforced manifest. Markdown file with a YAML frontmatter block (parser unchanged in
mechanism — `Manifest.load/1`). v2 replaces the flat `connectors:`/`outputs:` lists with a
`grants:` list carrying a per-grant constraints sub-block, and extends `spend` and `triggers`.

Privileged-read for the gate only: this file is loaded host-side and MUST NOT be mounted into
the container nor serialized into the port-boundary payload (see [boundary.md](./boundary.md)).

## Schema

```yaml
purpose: "<one-line contract>"           # unchanged (Phase 1)

triggers:                                 # FR-014
  - type: time                            # existing daily timer
    at: "07:00"
  - type: event                           # NEW — in-BEAM event trigger
    name: "<event-name>"
  - type: message                         # NEW — in-BEAM message trigger

grants:                                   # FR-001/002 — replaces connectors:/outputs:; SCOPE ONLY
  - connector: <string>                   # a connector name from the registry (generic capability)
    recipients: [<string>, ...]           # allowed recipients (omit if N/A to this connector)
    methods: [<string>, ...]              # allowed methods/endpoints (omit if N/A)
    # NOTE: requires_approval, credential, and cost are NOT set here — they are intrinsic
    # to the connector (see connector-registry.md). The author cannot downgrade danger.

mounts:                                   # unchanged
  - <state-mount-name>

spend:                                    # FR-010
  cap: <number >= 0>                      # max summed cost per window
  window: daily                           # fixed, resetting window (v2: daily) — FR-011
  on_breach: kill                         # v2: kill only — FR-012

owner: human                              # unchanged
supervision: restart-once-and-alert       # unchanged
```

## Worked example (discovery agent, v2)

```yaml
purpose: "Surface high-signal AI/ML content from the people-roster; read-and-digest only."
triggers:
  - type: time
    at: "07:00"
  - type: message
grants:
  - connector: kv_append           # local state write; registry: not credentialed, no approval
    methods: [append]
  - connector: external_send       # credentialed mock connector; registry: requires approval + credential
    recipients: ["owner-inbox"]    # this agent may only send here
    methods: [send]
mounts:
  - roster_trust
spend:
  cap: 5
  window: daily
  on_breach: kill
owner: human
supervision: restart-once-and-alert
```

## Validation rules

- `grants` and `spend` are REQUIRED; absence, a malformed grant, or a `connector` not present in
  the registry fails provisioning loudly (FR-016) — the agent is not provisioned.
- An action the agent proposes with no matching `grants[].connector` is rejected (default-deny,
  FR-003).
- `recipients`/`methods` are matched by membership when present; an out-of-scope value is a
  reject (FR-003).
- `spend.window` is `daily` and `spend.on_breach` is `kill` in v2; other values are rejected at
  parse time (forward-compatible enums, but only these implemented).
- `provisioner.check_drift/0` compares the hard-wired `config :agent` grants against this schema;
  drift is logged (Phase 1 behaviour, extended to the new fields).
