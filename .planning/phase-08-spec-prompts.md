# Phase 8 — Spec Prompts (Connector Ecosystem, v7)

Drafted `/speckit-specify` prompts for the two outstanding Phase 8 plans. Plan **08-01**
(pluggable connector registry) already landed (commit f9f2a43); these prompts cover the
remaining **08-02** and **08-03**, and are written against the *post-08-01* code
(auto-discovered `AgentOS.Connector` behaviour, generic effector dispatch + credential
resolution).

Paste each prompt after `/speckit-specify` when you're ready to open that spec.

## Ordering & dependencies

Both depend on **08-01** (done). 08-02 and 08-03 are independent of each other and may be
specced/built in either order — 08-02 grows the connector *channel* (synchronous tools),
08-03 grows the connector *trust/loading boundary* (third-party plugins). Nothing in Phase
9 depends on either, but 09-02's `store_find`/`store_append` will ride the same
auto-discovered registry, and an agent-initiated `kv_read` *tool* (noted in the roadmap) is
a natural later tenant of the 08-02 channel — do not build it speculatively.

Note both prompts still use the single `requires_approval?` flag, because the flag split
into `requires_deploy_consent?` / `requires_runtime_approval?` is **09-01**, not Phase 8.

---

## 08-02 — Synchronous tools + web_search

```
/speckit-specify Add a synchronous, mid-inference tool-use channel over the inference broker, and land `web_search` as the first tool connector.

## Problem
Today a connector can only produce an effect AFTER the agent has finished reasoning. The flow is one-way: the agent builds its messages, calls the inference broker over the mounted UDS (`agents/discovery/main.py` `call_inference_broker` → `POST /v1/inference` on the `AgentOS.InferenceBroker` listener, lib/agent_os/inference_broker.ex), gets a single completion back, prints its enumerated proposed actions on stdout, and only THEN does the substrate run them through the gate (lib/agent_os/gate.ex) and the effector (lib/agent_os/effector.ex). Each connector's `execute/2` (the `AgentOS.Connector` behaviour, lib/agent_os/connector.ex) returns `:ok | {:error, …}` — a post-approval *effect*, not a value fed back into reasoning.

There is no way for the agent to consult a capability MID-reasoning and fold the result into the same inference pass. A discovery/monitoring agent that needs to look something up on the open web must have that information already in its input payload — it cannot ask a question, receive an answer, and reason further in one turn. `web_search` is the motivating first case; a selective `kv_read` tool is the obvious second (deferred — see out of scope).

08-01 deliberately did NOT add a tool-channel callback; this plan adds it.

## Desired behaviour
Add a synchronous tool-use channel that runs THROUGH the inference broker in a single agent pass:

1. The agent issues one inference request as today. If the manifest grants tool connectors, the broker advertises those tools to the model (tool schemas derived from the connector metadata/registry — the agent does not hand-roll them).
2. When the model's response asks to use a tool, the broker pauses the completion, the substrate runs that tool query, and the result is injected back into the model context — the reasoning continues in the SAME pass until the model returns a final completion. The agent code sees one request/response; the tool loop is substrate-side, not agent-orchestrated.
3. A tool call is gated exactly like any other capability: the tool connector must be granted in the manifest (no grant → the tool is not offered and any attempt is refused), and the grant's scope (methods/recipients) still bounds it. Enforcement is unchanged — the deterministic gate remains the authority, world-B stays green.
4. Each tool invocation is metered at the inference chokepoint against the same per-agent spend cap that already governs model tokens (per-query cost for `web_search`); a breach triggers the existing kill-on-breach.
5. A tool that raises, hangs, or errors is fault-contained the same way effector execution is (timeboxed + rescue-wrapped → fail-closed result fed back to the model as a tool error, never crashing the run worker or the broker).

### The tool connector shape
Extend the `AgentOS.Connector` behaviour with a tool channel distinct from the post-approval `execute/2` effect: a synchronous callback that TAKES a query/arguments and RETURNS a result value to inject into context (not `:ok`). A connector may be effect-only (today's four), tool-only, or both; the registry auto-discovery from 08-01 is reused unchanged — dropping in a tool connector module is all that's needed, no central list edited.

### web_search, the first tool connector
Land `web_search` as one self-contained module under lib/agent_os/connector/:
- Classifies as a metered, credential-bearing tool: `credential: :search_api_key` (resolved declared-id → env var by the generic credential path from 08-01), `cost` set to the per-query micro-dollar price so it meters against the spend cap.
- Executes synchronously mid-reasoning: given a query, returns results into the model context in the same pass.
- Gated by the manifest grant — an agent without the `web_search` grant is never offered the tool and cannot call it.

## Acceptance criteria
- With a `web_search` grant, an agent can ask a question mid-reasoning, receive results, and reason further to a final completion within a single inference pass (one agent-side request/response).
- Without the grant, the tool is not advertised to the model and any forced attempt is refused by the gate — no call is made.
- Each `web_search` query meters its per-query cost against the per-agent spend cap; exhausting the cap triggers the existing kill-on-breach, and no tool call escapes metering.
- Adding a tool connector is dropping ONE module under lib/agent_os/connector/ (auto-discovered via the behaviour) with no edit to `Gate`, `Effector`, the registry list, `CredentialSource`, or `CapabilityRender`.
- A tool that raises or hangs fails closed (bounded, logged loudly) and is surfaced to the model as a tool error without crashing the run worker or the broker.
- The world-B suite is unchanged and green; the existing four effect connectors are unaffected.
- Tests run with no Docker and no network (the web_search upstream is stubbed/mocked in the suite).

## Out of scope
- An agent-initiated `kv_read` tool (selective/synchronous state read driven by reasoning). The channel is the right home for it, but reads stay mounts, not grants, until a concrete agent needs to pull a key mid-reasoning — do not build speculatively.
- Multi-tool planning/agentic loops beyond "model asks → substrate answers → continue"; parallel tool fan-out.
- Any new admission/loading/compile-isolation machinery for third-party connectors (that is 08-03).
- Changing the effect connectors from writing state to returning effects (contract isolation T1 — deferred to 08-03).
- Changes to how the spend cap or kill-on-breach fundamentally work (this only adds tool-call cost as another metered line item).
```

---

## 08-03 — Connector admission & compile-isolated plugins

```
/speckit-specify Establish the trust and loading boundary for third-party connectors: contract isolation, compile isolation, dynamic loading, and an admission gate.

## Problem
After 08-01, adding a connector means dropping a module implementing the `AgentOS.Connector` behaviour (lib/agent_os/connector.ex) under lib/agent_os/connector/ — auto-discovered, no central list to edit. That is exactly right for FIRST-PARTY connectors, and all v7 connectors are first-party. But connector code runs INSIDE the trusted substrate (the effector calls `mod.execute/2` in-process, lib/agent_os/effector.ex; a tool connector from 08-02 runs mid-inference), and today nothing separates a connector from the core:

1. **No contract isolation (T1).** A connector may touch substrate state directly — `kv_append` calls `AgentOS.StateStore.apply_action("roster_trust", …)` straight from `execute/2` (lib/agent_os/connector/kv_append.ex). A connector is trusted to reach into the substrate rather than being confined to returning a described effect the substrate applies.
2. **No compile isolation.** Connectors compile into the core Mix app, so a connector that fails to compile (or pulls a bad dependency) breaks the whole substrate build.
3. **No dynamic loading.** Adding a connector requires rebuilding the core; there is no install-without-rebuild path.
4. **No admission gate.** Because connector code executes in the trusted substrate, a third-party connector is a code-trust decision — but there is no review step and no way to provision its credentials as part of admitting it.

This is the point where "no editing core code to add a connector" must fully land for authors who are NOT the substrate team.

## Desired behaviour
Turn the connector boundary from "trusted first-party module" into "admitted plugin", along four axes:

- **Contract isolation (T1).** A connector returns a DESCRIBED effect; the substrate applies it. A connector no longer calls `StateStore` (or any substrate mutator) directly. Migrate `kv_append` (and any other direct-touch connector) so `execute/2` returns an effect value that the effector applies at the chokepoint — the connector never holds a substrate handle. First-party effect connectors keep working identically from the caller's view.
- **Compile isolation.** A connector is a separate Mix app / package, so a connector that fails to compile or misbehaves at build time cannot break the core build. The core depends on the connector contract, not on any specific connector's source.
- **Dynamic loading.** A connector can be installed and made discoverable WITHOUT rebuilding the core substrate. The 08-01 auto-discovery already scans dynamically loaded `Elixir.AgentOS.Connector.*` modules; this plan makes that a supported install path rather than a test affordance.
- **Admission gate.** Admitting a third-party connector is an explicit reviewed decision (its code runs in the trusted substrate) that also provisions any credential the connector declares (declared id → credential source). An un-admitted connector is not discoverable/usable; admission is where the human vouches for the code and wires its secret.

Enforcement is unchanged throughout: the deterministic gate still validates every action against the manifest grants, credentials still inject only at the effector chokepoint post-approval, and world-B stays green.

## Acceptance criteria
- No connector calls `StateStore` (or any substrate-state mutator) directly from `execute/2`; connectors return a described effect that the substrate applies. `kv_append` is migrated to the effect-return contract with behaviour unchanged for callers, and world-B stays green.
- Connectors live in a separate compilation unit (Mix app / package): a connector that fails to compile does not break the core substrate build.
- A connector can be installed and become discoverable/usable without rebuilding the core; an un-admitted connector is not discoverable.
- Admitting a connector is an explicit reviewed step that provisions its declared credential (declared id → credential source) before the connector can execute; without admission the connector cannot run.
- The existing four connectors continue to run on the pluggable path; the world-B suite is unchanged and green.
- Tests run with no Docker and no network.

## Out of scope
- The synchronous tool channel and `web_search` (08-02).
- A public connector marketplace/distribution, versioning, or signing infrastructure beyond the local admission decision.
- Any change to the gate's validation logic, spend metering, or approval flags.
- Sandboxing connector code in a separate OS process/container — the admission gate is a code-trust decision, not a runtime sandbox for connectors, in this plan.
```
