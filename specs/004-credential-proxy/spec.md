# Feature Specification: Credential Proxy

**Feature Branch**: `004-credential-proxy`
**Created**: 2026-06-29
**Status**: Draft
**Input**: User description: "Credential proxy: no LLM-running component ever holds a mutating credential. Roadmap plan 03-03 of Agent OS (Phase 3, Manifest Enforcement / v2). Carves User Story 3 of specs/002-manifest-enforcement into its own feature — the way US2 was carved into specs/003-manifest-invisibility — to become spec 004-credential-proxy. Makes Constitution Principle XI real: even a fully compromised agent cannot act, because it never holds the means to act."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A credentialed action runs only via chokepoint injection (Priority: P1)

As the operator of the substrate, I need the secret that authorizes a mutating action to be held only inside the control plane and handed to the action's execution sink at the moment of execution — after the gate has approved the action, and nowhere else. The component that runs the LLM (the agent workload across the port boundary) proposes the action but never possesses the credential, so it physically cannot perform the action on its own.

**Why this priority**: This is the structural guarantee behind the gate. The gate decides whether an action is *allowed*; the proxy ensures the agent could not perform the action even if it bypassed the gate, because it never holds the credential. It is the only story in this feature; everything else supports it. It is a precondition for "v2 done" and a hard dependency of generation (v3) — auto-deploying machine-written agents is sound only if a rogue agent is physically incapable of acting on its own.

**Independent Test**: Drive a gate-approved `external_send` action through the effector and confirm (a) the action's sink executes and records the delivered payload to a test-observable sink, (b) the sink executed only because a credential was injected, and (c) the credential value is present only inside the injected closure at injection time — absent from the agent's environment, the boundary payload, the return value handed back to the caller, the run-trace, the inventory, and any log. Fully verifiable by an automated test with a mock sink — no live external service, no live LLM, no Docker.

**Acceptance Scenarios**:

1. **Given** a gate-approved action whose connector declares a credential, **When** the effector executes it, **Then** the credential is obtained from the proxy and injected at the sink call site, and the sink executes successfully with it.
2. **Given** an approved action whose connector declares a credential, **When** the effector executes it, **Then** the secret is present only inside the injected closure at injection time and is never returned to the caller, logged, persisted, written to the run-trace, or written to the inventory.
3. **Given** any run, **When** the agent's environment and boundary payload are inspected, **Then** no mutating credential is present anywhere the agent can read (extending the boundary invariant proven in 003-manifest-invisibility to credentials specifically).
4. **Given** an approved action whose connector declares **no** credential (e.g. `kv_append`), **When** the effector executes it, **Then** no credential is requested from the proxy and the action runs unchanged.
5. **Given** the credential proxy holds an inference-only credential (a read-only model key) alongside a mutating credential, **When** the proxy serves a mutating-action request, **Then** the two are held under distinct keys and an inference-only key is never served as a mutating credential.

### Edge Cases

- **Unknown / absent credential**: What happens when an approved action's connector declares a credential id that the proxy has not loaded (missing from app/OS env)? The execution MUST fail closed with a clear error rather than running the sink with an empty or default secret. No partial side effect, nothing leaked.
- **Closure raises**: If the function the proxy runs against the secret raises, the secret MUST NOT leak via the exception, log, or stack trace, and the proxy MUST NOT return the secret to the caller as part of any error.
- **Connector declares no credential**: An action whose connector has `credential: nil` must execute without ever contacting the proxy (vacuous pass; no error).
- **Inspection of proxy state**: A crash dump or process inspection of the proxy is out of test scope, but the API surface MUST be such that the secret is never the return value of a public call — only ever the argument handed to a supplied function.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The control plane MUST provide a credential proxy that holds capabilities (secrets/tokens) keyed by the connector capability registry's `credential` id, loaded from application/OS environment configuration.
- **FR-002**: The proxy MUST expose a `with_credential(credential_id, fun)`-style API that hands the secret to a caller-supplied function and never returns the secret to the caller (the call's result is the function's result, never the secret itself).
- **FR-003**: The proxy MUST be a single-writer process in the supervision tree, consistent with the substrate's single-writer-for-owned-state architecture.
- **FR-004**: When the effector executes a gate-approved action whose connector declares a `credential` in the registry, it MUST obtain that credential from the proxy and inject it at the sink call site — only at action time, only after gate approval, and nowhere else.
- **FR-005**: When the effector executes a gate-approved action whose connector declares no credential, it MUST NOT contact the proxy and MUST execute the action unchanged.
- **FR-006**: A mutating credential MUST NOT be present in the agent's environment or in the boundary payload sent across the port (this feature extends the 003 boundary invariant to assert credentials specifically).
- **FR-007**: A mutating credential MUST NOT be logged, persisted, written to the run-trace, or written to the inventory at any point.
- **FR-008**: Inference-only credentials (e.g. a read-only model key) MUST be held under keys distinct from mutating credentials, and an inference-only credential MUST never be served in response to a mutating-action request.
- **FR-009**: If an approved action's connector declares a credential id that the proxy cannot resolve, execution MUST fail closed with a clear error and no side effect, and MUST NOT fall back to an empty or default secret.
- **FR-010**: The `external_send` connector MUST be exercised through a mock sink that records the delivered payload to a test-observable destination and executes only when a credential has been injected — with no live external service, no live LLM, and no Docker required for the tests.
- **FR-011**: The credential-proxy and effector modules MUST carry an explicit, discoverable statement that no LLM-running component holds a mutating credential and that injection happens only at the post-approval chokepoint.

### Key Entities *(include if feature involves data)*

- **Credential Proxy**: The control-plane holder of capabilities. Holds secrets keyed by registry `credential` id, serves them only into a caller-supplied closure, and never returns or exposes them otherwise. Single-writer, in the supervision tree.
- **Capability credential id**: The `credential` field on a connector in the capability registry (e.g. `external_send → :outbound_token`). The key that ties a connector to the secret the proxy injects; `nil` means the connector needs no credential.
- **Mutating credential**: A secret that authorizes an outbound or state-changing connector action. Held only in the proxy; never crosses the port boundary, never logged or persisted.
- **Inference-only credential**: A read-only credential (e.g. a model key) that does not authorize state mutation. Held under a distinct key from mutating credentials.
- **Chokepoint / sink call site**: The single deterministic point in the effector where a gate-approved credentialed action is executed and where, and only where, the credential is injected.
- **Mock sink (`external_send`)**: A test-observable connector body that records its delivered payload and runs only with an injected credential, standing in for a live external service.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of credentialed gate-approved actions execute with the credential injected at the chokepoint; the credential appears in 0 agent-reachable surfaces (environment, boundary payload), verified automatically.
- **SC-002**: The mutating credential value appears in 0 log lines, 0 run-trace entries, and 0 inventory entries across a full run, verified automatically.
- **SC-003**: 0 public proxy calls return the secret as their result; the secret is only ever the argument passed to the supplied function, verified by the proxy's contract test.
- **SC-004**: An approved action whose connector declares an unresolvable credential id fails closed in 100% of cases with no side effect (the mock sink records nothing).
- **SC-005**: An approved non-credentialed action (e.g. `kv_append`) completes without any proxy interaction in 100% of cases.
- **SC-006**: A reader of the credential-proxy and effector modules can determine, from in-code documentation alone, that no LLM-running component holds a mutating credential and that injection occurs only post-approval at the chokepoint.

## Assumptions

- The connector capability registry already carries the `credential` field per connector (`external_send → :outbound_token`, `kv_append → nil`), established in spec 002; this feature consumes it rather than redefining it.
- The effector is already the sole privileged execution path and is already wired into the gate→effector run phase (spec 002); this feature fills the `external_send` chokepoint that currently no-ops awaiting the proxy.
- The 003 boundary invariant (no envelope/credential on agent-reachable surfaces) is in place; this feature adds a credential-specific assertion that exercises the real proxy/effector path rather than reconstructing it.
- "Mutating credential" means any secret authorizing an outbound or state-changing action; read-only run data and inference-only keys are not mutating credentials.
- Secrets are loaded from application/OS environment configuration at startup; secret rotation, a secrets-manager backend, and encryption-at-rest are out of scope for this feature.
- The gate's allow/deny logic is unchanged here (spec 002, plan 03-01); this feature only adds credential injection downstream of an approval.

## Out of Scope

- Spend metering and kill-on-breach (roadmap plan 03-04).
- Event-triggers and message-triggers, including approval-as-event-trigger (roadmap plan 03-05).
- World-B hostile-agent verification that the gate physically prevents breach regardless of agent code (roadmap plan 03-06).
- Any change to the gate's allow/deny logic (roadmap plan 03-01, already done).
- Live external services, live LLM calls, real secret backends, and any generation (v3) work.
