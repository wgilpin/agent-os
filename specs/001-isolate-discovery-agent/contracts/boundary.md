# Contract: Port Boundary (substrate ↔ container)

The JSON exchanged across the port boundary. Shape is unchanged from Phase 1; Phase 2 adds
schema validation on **both** sides (Elixir `Sanitizer` out, Python Pydantic in).

## Input (substrate → container, via stdin, one line)

```json
{
  "state": { "...": "snapshot of the agent's granted mount" },
  "items": [
    { "id": "string", "author": "string", "text": "string", "urls": ["string"] }
  ]
}
```

- `state`: a snapshot of the agent's granted state mount, passed generically by the mount
  name declared in the agent's manifest. The substrate does not know or hard-code what the
  mount contains — for the discovery agent it happens to be a roster/trust store.
- `items`: array of **sanitized** untrusted items (see data-model.md). May be empty.
- Exactly one JSON line is written to the container's stdin, terminated by `\n` (matches
  the Phase 1 single-line read).
- The container MUST validate this against its Pydantic model and exit non-zero with a
  logged error if it fails (defense-in-depth; should never trip because the substrate
  already sanitized).

## Output (container → stdout)

```json
{
  "actions": [
    { "type": "append_digest", "payload": { "text": "string" } }
  ]
}
```

- The action `type` values are those the agent's manifest declares as `outputs` (the
  discovery agent declares `append_digest`). The substrate's `OutputCheck` validates the
  action list and the `Effector` applies the privileged write — dispatched by the
  manifest-declared action name, not a hard-coded one. The agent never writes state itself
  (Constitution X).
- The container MUST NOT print anything else to stdout (logs go to stderr).

## Exit semantics

| Exit | Meaning | Substrate action |
|------|---------|------------------|
| `0` | Success; valid action list on stdout | collect → OutputCheck → Effector → Run Record `:ok` |
| `137` | OOM-killed | Run Record `:failed("oom")` → restart-once-and-alert |
| other ≠0 | Crash / bad input / agent error | Run Record `:failed("crash")` → restart-once-and-alert |
| (no exit before `timeout_ms`) | Hang | wrapper stops container → `:failed("timeout")` |
