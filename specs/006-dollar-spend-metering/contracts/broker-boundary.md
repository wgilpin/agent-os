# Contract: Agent ↔ Broker Boundary (wire + identity)

How the sandboxed Python workload reaches the broker, and how identity is bound so the untrusted
agent cannot spoof another agent's cap or budget (R1, R2). This is the deliberate boundary change
the spec calls "the point" (FR-001).

## Transport

- The substrate mounts a **unix-domain socket** into the container; `network: "none"` is kept, so
  the socket is the container's only channel out (R1). Egress is set by `Sandbox.build_argv`, never
  by the agent (Principle X — no self-conferred authority).
- The broker listens on that socket (OTP stdlib listener; no new dependency) and serves
  `POST /v1/inference`.
- Fallback (if a model client cannot speak HTTP-over-UDS): an `internal: true` docker network with
  the broker as the sole reachable host. Same isolation guarantee, larger surface.

## Per-run identity token

- The substrate generates an opaque per-run token, injects it into the container env, and registers
  `token → {agent_name, manifest}` with the broker before the run starts.
- The agent includes the token on every request; the broker resolves the agent **server-side**.
- The token is invalidated when the run ends. Unknown/expired token ⇒ `{:error, :unknown_run_token}`
  (fail closed).
- The agent cannot present another agent's identity, a different cap, or a price — none of those
  cross the boundary (FR-002, FR-012).

## Request (agent → broker)

`POST /v1/inference`
```json
{ "run_token": "<opaque>", "model": "gemini-3-flash-preview", "messages": [ ... ] }
```
Exactly these fields. No envelope data (grants, spend, cap, price) — spec 003 invisibility.

## Response (broker → agent)

| Status | Body | Meaning |
|--------|------|---------|
| `200` | `{ "completion": ... }` | Success. Only the completion (no usage/price/cap/spend). |
| `402` | `{ "error": "spend_breach" }` | Cap reached/crossed; no further inference (FR-014). |
| `4xx` | `{ "error": "unpriced_model" }` | Fail-closed: model not in the price table (FR-015). |
| `4xx` | `{ "error": "unknown_run_token" }` | Fail-closed: identity not resolvable. |

## Python workload obligation (`agents/discovery/main.py`)

- Point the model client at the broker socket; read the per-run token from env.
- Hold **no** provider key (it has none — the broker holds `:model_key`). The agent cannot call the
  provider out-of-band (FR-001, Principle XI).
- On a `spend_breach`/error response, the agent has no further inference available regardless of how
  it behaves — the broker enforces the stop server-side.

## Test note

Per Constitution III/IV, the Python shim and the live socket transport are **not** unit-tested; the
metering/cap/breach semantics are verified against `InferenceBroker.complete/2` directly with a mock
provider. The wire contract here is exercised by manual walkthrough / integration only.
