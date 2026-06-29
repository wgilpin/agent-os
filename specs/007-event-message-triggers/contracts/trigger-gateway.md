# Contract: TriggerGateway — Intake & Dispatch

`AgentOS.TriggerGateway` is the **only** substrate-side intake for events, messages, and approvals. It is a
`GenServer` in the supervision tree. All callers are substrate-side processes (Scheduler, operator-chat
adapter, any external feed adapter); the sandboxed agent has no channel to it.

## Public API

```elixir
@type signal ::
        {:event, name :: String.t(), payload :: term()}
        | {:message, agent :: String.t(), content :: term()}
        | {:approval, :approve | :deny, ref :: String.t()}

# Submit an admitted signal. Async; the dispatch outcome is observable in the run-log / inventory.
@spec submit(signal()) :: :ok

# Test/operator-synchronous variant returning the dispatch decision (no real run/effect when injected).
@spec submit_sync(signal(), keyword()) ::
        {:fired, [agent :: String.t()]}      # event/message: agents that fired (possibly [])
        | {:resolved, :approved | :denied | :unknown_ref}  # approval outcome
        | {:rejected, reason :: atom()}       # default-deny / malformed / unknown agent
```

Dependency-injection opts (tests; Constitution IV): `:start_run_fn` (default `&RunSupervisor.start_run/1`),
`:effector_fn` (default `&Effector.act/1`), `:manifests_fn` (default loads the configured manifest(s)),
`:now`.

## Behaviour — `:event`

1. Load the manifest(s); collect agents whose triggers contain `%{type: :event, name: ^name}`.
2. For **each** such agent, call `start_run_fn.(trigger: "event:" <> name, trigger_input: payload, agent: agent)`.
3. Return `{:fired, agents}`. If no agent matches, **fire nothing** and return `{:fired, []}` (default-deny,
   FR-002), logging a distinct "no agent declares event <name>" line.

**Guarantees**: exactly one `start_run` per matching agent per admitted event (one-signal→one-run per
target, FR-013). The payload is delivered as run input (FR-001). An event name appearing in agent output or
web input never reaches this function (origin invariant, FR-010).

## Behaviour — `:message`

1. Look up `agent` in the inventory. If absent → `{:rejected, :unknown_agent}`, logged (edge case).
2. If the agent's manifest has no `%{type: :message}` → `{:rejected, :no_message_trigger}`, fire nothing
   (FR-004).
3. Else call `start_run_fn.(trigger: "message", trigger_input: content, agent: agent)` and return
   `{:fired, [agent]}` (FR-003). The operator-chat adapter is just another caller of `submit/1` — no
   privileged path (FR-005).

## Behaviour — `:approval`

Delegated to the approval-resume contract: see [approval-resume.md](./approval-resume.md). Returns
`{:resolved, :approved | :denied | :unknown_ref}`.

## Invariants (all variants)

- **Substrate-only origin**: signals are constructed by substrate-side callers; never from agent stdout or
  untrusted web input (FR-010, Principle X).
- **Manifest allowlist**: eligibility is read from the manifest; absence ⇒ deny (FR-002, FR-004).
- **No bypass**: every fire goes through `RunSupervisor.start_run/1`, so the gate, credential proxy, and
  spend metering all still apply to event/message-fired runs (FR-015).
- **Agent-agnostic**: no event name or agent identity is hard-coded; all come from manifest data
  (Principle IX).
- **Loud rejects**: every reject/no-match logs a distinct line (Principle VI).

## Test contract (`trigger_gateway_test.exs`)

- event matching a manifest trigger → exactly one `start_run` with `trigger: "event:<name>"` and the payload.
- event with no matching manifest trigger → zero `start_run`; `{:fired, []}`.
- agent with no event trigger → unaffected by any event.
- message to a message-triggered agent → one `start_run` with `trigger: "message"` and the content.
- message to an agent lacking a message trigger → `{:rejected, :no_message_trigger}`, zero `start_run`.
- message to an unknown agent → `{:rejected, :unknown_agent}`, zero `start_run`.
- two identical events → two `start_run` calls (one per admitted signal), never collapsed/dropped.
