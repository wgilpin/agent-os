# Feature Specification: Agent Runtime Kit (`agent_os_runtime`)

**Feature Branch**: `046-agent-runtime-kit`
**Created**: 2026-07-12
**Status**: Draft
**Input**: User description: "Create `agent_os_runtime`, a first-party Python runtime kit baked into the generated-agent image, so generated agent bodies stop hand-rolling raw HTTP-over-UDS transport and gain a framework-grade agent loop (typed tools, bounded retries, structured output, message history) — while the trust boundary stays exactly where it is: the kit is DX, the gate and sandbox remain the only enforcement."

## Context

Every generated agent body currently re-invents ~40 lines of raw AF_UNIX HTTP/1.1 socket code and makes exactly one inference call (e.g. `call_inference_broker` in `agents/get_the_local_time_*/main.py` — hand-rolled request assembly, header parsing, status handling, freshly LLM-generated per agent). This is a per-agent bug surface, it makes multi-step tool-loop agents impossible to generate reliably, and it bloats what Stage 4 emits and what the judge and Stage-5 security review must audit.

The framework decision is already made empirically (`pydantic-ai-slim[openai]==2.5.0`, per `.planning/bakeoff-agent-framework/SCORECARD.md`): first-class UDS transport, offline-total under an AF_UNIX-only jail, zero uncommanded calls, retries bounded and visible. This feature lands the kit and the transport. Tool-stub codegen from the connector registry is 13-02; the Stage-4 generation contract is 13-03.

### Trust boundary (unchanged)

The kit runs INSIDE the untrusted sandboxed body. Its typing/validation is developer experience and early failure, **never enforcement**: the gate still validates every action against the manifest, the broker still meters every call, and the sandbox (network=none; the UDS is the only reachable endpoint) physically disables the framework's native tools / MCP / direct-provider egress. Nothing in this feature touches `lib/agent_os/gate.ex`, manifest semantics, or the world-B invariants. A body that bypasses the kit and hand-rolls transport is not blocked by the kit — it is constrained exactly as before, by the sandbox and the broker.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A generated agent body runs a multi-step tool loop with zero transport code (Priority: P1)

An agent author (in practice: Stage-4 generation) writes an agent body that imports the kit, declares its tools and typed output, and runs. The body contains no socket code, no environment-variable plumbing, and no HTTP assembly — the kit resolves the broker endpoint from the environment contract the sandbox already injects (`INFERENCE_SOCKET`, `RUN_TOKEN`, `AGENT_MODEL`) and drives the full model/tool loop over the mounted UDS.

**Why this priority**: This is the core value — eliminating the per-agent transport bug surface and unlocking reliable multi-step agents. Without it nothing else in the feature matters.

**Independent Test**: A sample kit-based agent body of under 30 lines completes a golden multi-step task (2+ sequential tool calls, e.g. search_notes → add_todo → final result) against a test broker over the UDS, run across the existing port boundary (stdin payload in, one outcome-record line out).

**Acceptance Scenarios**:

1. **Given** the sandbox-injected environment contract and a mounted broker UDS, **When** the sample body runs with a task payload on stdin, **Then** it completes the golden multi-step task and emits exactly one outcome-record line on stdout.
2. **Given** the sample body source, **When** it is inspected, **Then** it is under 30 lines and contains zero socket, HTTP, header, or env-var transport handling.
3. **Given** a required environment variable is missing (e.g. `RUN_TOKEN`), **When** the kit initialises, **Then** it fails immediately with a clear error in the outcome record rather than attempting a call.
4. **Given** the model requests a tool that raises or returns invalid data, **When** the kit's bounded retry budget (default 2) is exhausted, **Then** the run ends with a structured failure outcome — no unbounded retry loops, and every retry attempt is a discrete broker request.

---

### User Story 2 - The broker speaks the framework's native protocol with identical chokepoint semantics (Priority: P1)

The inference broker gains an OpenAI-compatible chat-completions surface (`/v1/chat/completions`, run token presented as a Bearer token in the `Authorization` header) that maps onto the existing metering/validation path. The framework talks to the broker unmodified; the operator's spend metering, per-call cap, and kill-on-breach behave identically to the native `/v1/inference` envelope path.

**Why this priority**: Without a protocol bridge the kit cannot talk to the broker at all; and if the bridge weakened metering it would move the trust boundary, which is explicitly forbidden.

**Independent Test**: Broker-level tests exercise the new surface directly: valid token → metered completion; invalid/expired token → rejection; oversized call → per-call cap rejection; cumulative breach → same kill behaviour as the native path.

**Acceptance Scenarios**:

1. **Given** a valid run token in the Authorization header, **When** an OpenAI-shaped chat-completions request arrives, **Then** the broker validates, meters, and forwards it on the same path as the native envelope and returns an OpenAI-shaped response the framework accepts.
2. **Given** a missing, malformed, or expired run token, **When** a request arrives on the new surface, **Then** it is rejected without any upstream call and without metering spend.
3. **Given** a run at its per-call cap or aggregate budget, **When** the kit issues the next call, **Then** cap enforcement and kill-on-breach fire exactly as they do on the native path.
4. **Given** a kit-driven run issuing N model calls (including retries), **When** the broker log is reconciled, **Then** exactly N discrete metered requests appear — spend reconciles call-for-call.
5. **Given** existing generated agents using the native `/v1/inference` envelope, **When** they run, **Then** their behaviour is unchanged.

---

### User Story 3 - The same body works as a future chat turn: history in, delta out (Priority: P2)

The kit's invocation wrapper is session-shaped from day one: the input payload may carry an optional `history` field (prior conversation messages), and the outcome record carries the new messages produced by this run. A future chat-turn agent (Phase 14) is the same body invoked with history — no body changes. The substrate persists history; the kit only threads it through.

**Why this priority**: Cheap to build now, expensive to retrofit later — it fixes the body contract before Stage-4 generation (13-03) starts emitting bodies against it.

**Independent Test**: Run the sample body twice: once with no history, once with the first run's history delta fed back in; the second run demonstrably continues the conversation (the model sees prior messages) and returns a new delta.

**Acceptance Scenarios**:

1. **Given** an input payload with no `history` field, **When** the body runs, **Then** it behaves as a fresh run and the outcome record contains the full set of new messages as the history delta.
2. **Given** an input payload carrying a prior history delta, **When** the body runs, **Then** the model receives the prior messages as conversation context and the outcome record contains only the messages new to this run.
3. **Given** a malformed `history` field, **When** the body runs, **Then** the kit fails fast with a structured error outcome rather than silently dropping history.

---

### User Story 4 - The kit is pinned, baked, and provably offline (Priority: P2)

The kit and its framework dependency (`pydantic-ai-slim[openai]==2.5.0`, exact pin) are installed into the generated-agent runtime image at image build time — no floating versions, no installation at agent-provision time. A `--network=none` container run of the sample kit-based agent completes the golden task with zero egress attempts, including proving that no dependency (tiktoken sits in the tree) lazily downloads assets.

**Why this priority**: The offline guarantee is what keeps the sandbox story honest; the pin is what makes the kit's behaviour reproducible and auditable. Both are prerequisites for trusting anything Story 1 demonstrates.

**Independent Test**: Build the image; run the sample agent under `--network=none` with only the UDS mounted; assert task success and zero egress attempts (extends the spec-044 containment probe). The Python-side regression harness (seeded from the bake-off harness: stub UDS broker + AF_UNIX-only socket jail) runs green and is documented as the gate for any future pin bump.

**Acceptance Scenarios**:

1. **Given** the built generated-agent image, **When** its installed packages are inspected, **Then** the kit and framework are present at exact pinned versions and no agent-provision step installs Python packages.
2. **Given** a `--network=none` run of the sample agent with the UDS mounted, **When** the golden task executes, **Then** it completes with zero egress attempts and no lazy asset downloads.
3. **Given** a proposed framework version bump, **When** the documented regression harness is run against the new pin, **Then** a green run is the required gate before the pin changes in the image.

---

### Edge Cases

- Missing or empty `INFERENCE_SOCKET` / `RUN_TOKEN` / `AGENT_MODEL`: kit fails fast at startup with a structured error outcome; no call attempted.
- Broker unreachable (socket absent or connection refused): bounded, visible retries then structured failure — never an unbounded reconnect loop.
- Broker rejects mid-loop (cap breach, kill-on-breach) partway through a multi-step tool sequence: the run terminates with a structured failure outcome; partial tool effects are reported honestly in the outcome record.
- Retry exhaustion on model or tool validation failure: structured failure after the explicit budget (default 2); each retry is a visible metered request.
- Socket path near the macOS AF_UNIX `sun_path` limit (~104 chars): test fixtures and documentation keep socket paths short; the kit surfaces a clear error if the path is too long rather than an opaque OS failure.
- Streaming or other OpenAI-surface features the broker does not support: the broker's compatibility surface rejects them cleanly (or the kit does not enable them); no silent partial support.
- A body that hand-rolls transport anyway: not the kit's problem — sandbox and broker constrain it exactly as today (DX, not enforcement).
- Oversized history payload or history containing malformed message structures: fail fast with a structured error, no silent truncation.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The substrate repo MUST provide a first-party Python package `agent_os_runtime` (top-level package directory alongside `agents/`, owned by the repo, never generated) exposing at minimum `substrate_model()` and `run_agent(agent, ...)`.
- **FR-002**: `substrate_model()` MUST return a framework model configured to speak to the inference broker over the mounted UDS, resolving connection details exclusively from the existing sandbox-injected environment contract (`INFERENCE_SOCKET`, `RUN_TOKEN`, `AGENT_MODEL`); agent bodies MUST NOT need to read these variables themselves.
- **FR-003**: The inference broker MUST expose an OpenAI-compatible chat-completions surface (`/v1/chat/completions`) that authenticates via the run token in the `Authorization: Bearer` header and maps onto the existing validation, metering, per-call cap, and kill-on-breach path with semantics identical to the native `/v1/inference` envelope. Kit-side request rewriting (e.g. httpx event hooks) is rejected as the mechanism unless implementation uncovers a hard blocker, in which case the spec must be revisited.
- **FR-004**: The native `/v1/inference` envelope path MUST remain unchanged; existing generated agents MUST keep working without modification.
- **FR-005**: `run_agent` MUST wrap the existing PortRunner stdin/stdout contract: one JSON payload line in (via stdin-guard), one outcome-record line out.
- **FR-006**: `run_agent` MUST accept an optional `history` field in the input payload (prior conversation messages), thread it into the framework's message-history mechanism, and append the run's new-message delta to the outcome record. The kit MUST NOT persist history — persistence belongs to the substrate.
- **FR-007**: The kit MUST set an explicit, bounded retry budget (default 2) for model/tool retries; every retry MUST surface as a discrete metered broker request. No framework feature that issues uncommanded calls (telemetry, background requests, implicit tool invocation, direct-provider fallback) may be enabled.
- **FR-008**: The kit and `pydantic-ai-slim[openai]==2.5.0` MUST be installed into the generated-agent runtime image (per spec 044) at image build time with exact version pins; no Python package installation may occur at agent-provision time.
- **FR-009**: The kit MUST fail fast with a structured error outcome when the environment contract is incomplete, the broker is unreachable, the history payload is malformed, or the retry budget is exhausted — never hang, never retry unboundedly, never exit without an outcome record.
- **FR-010**: A sample kit-based agent body MUST exist in the repo as the golden reference: under 30 lines, zero transport/env code, completing a multi-step (2+ sequential tool calls) task with history threaded in and delta out. Its tools are plain in-body functions (connector-registry tool stubs are 13-02).
- **FR-011**: An Elixir-side E2E test MUST run the sample body across the port boundary against a test broker instance (reusing the existing `start_broker_uds!/1` test helper) and verify the golden task, the outcome-record contract, and call-for-call spend reconciliation.
- **FR-012**: A Python-side test suite, seeded from the bake-off harness (stub UDS broker + AF_UNIX-only socket jail), MUST cover the kit's transport, retry, and history behaviour deterministically with no network, and MUST be documented as the mandatory regression gate for any future framework pin bump.
- **FR-013**: An in-image offline validation MUST run the sample agent in a `--network=none` container (extending the spec-044 containment probe) and assert golden-task success with zero egress attempts and no lazy asset downloads. Test socket paths MUST stay well under the macOS AF_UNIX path limit (~104 chars).
- **FR-014**: The feature MUST NOT modify the gate, manifest semantics, capability render, or any world-B invariant; the world-B suite MUST pass unchanged.

### Key Entities

- **Runtime kit (`agent_os_runtime`)**: First-party Python package baked into the generated-agent image; provides broker-connected model construction and the session-shaped invocation wrapper. DX and early failure only — no enforcement authority.
- **Agent body**: Untrusted, generated Python program running in the sandbox; consumes the kit; declares tools, instructions, and typed output; contains no transport code.
- **Inference broker**: Trusted Elixir chokepoint; now speaks two surfaces (native envelope + OpenAI-compatible chat-completions) over one metering/validation/cap path.
- **Invocation payload**: One JSON line on stdin: task input plus optional `history` (prior messages).
- **Outcome record**: One JSON line on stdout: run result (success or structured failure) plus the history delta (messages new to this run).
- **Environment contract**: `INFERENCE_SOCKET`, `RUN_TOKEN`, `AGENT_MODEL` — injected by the sandbox, consumed only by the kit.
- **Golden task**: Reference multi-step task (2+ sequential tool calls, bake-off shape: search_notes → add_todo → final result) used by every test tier.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A sample agent body of fewer than 30 lines completes the golden multi-step task (2+ sequential tool calls) against a test broker over the UDS, inside the sandboxed container, with history threaded in and delta out.
- **SC-002**: The sample body contains zero transport code and zero socket/env handling; hand-rolled HTTP of the `agents/*/main.py` style does not appear in any kit-based body.
- **SC-003**: Every model call and retry issued by the kit appears as a discrete metered broker request; spend reconciles call-for-call with the broker log; per-call cap and kill-on-breach behave identically to the native envelope path.
- **SC-004**: The `--network=none` in-image run passes with zero egress attempts and no lazy asset downloads (tiktoken proven never to fetch).
- **SC-005**: Kit and framework versions are pinned exact in the image; the regression harness runs green and is documented as the gate for any future pin bump.
- **SC-006**: The world-B suite passes unchanged; no diff touches the gate, manifest projection, or capability render.
- **SC-007**: Existing generated agents on the native envelope path run unchanged and green.

## Assumptions

- The framework choice (`pydantic-ai-slim[openai]==2.5.0`) is settled by the bake-off (`.planning/bakeoff-agent-framework/SCORECARD.md`) and is not re-litigated here; the kit is the seam behind which it could later be swapped.
- The broker-compatibility mechanism is decided in favour of a broker-side OpenAI-compatible surface (FR-003); kit-side request rewriting is explicitly rejected absent a hard blocker discovered during implementation.
- The sandbox-injected environment contract (`INFERENCE_SOCKET`, `RUN_TOKEN`, `AGENT_MODEL`) is stable and sufficient; no new environment variables are needed.
- The existing PortRunner stdin/stdout contract (one JSON line in via stdin-guard, one outcome-record line out) is the invocation shape; the kit extends the payload/record schema (history in, delta out) without breaking existing consumers, since existing agents do not use the kit.
- History message format follows the framework's native message-history serialisation; the substrate treats it as an opaque-but-JSON blob to persist and replay (Phase 14 owns persistence).
- The default retry budget of 2 (bake-off default) is acceptable as the kit default; it is a kit-level constant, not per-agent configuration, until a real need emerges.
- The spec-044 image build and containment probe are the extension points for baking the kit and proving offline behaviour; no new container plumbing is required.
- Deployment model is unchanged: single user, owner's Mac, OrbStack runtime.

## Out of Scope

- Tool-stub codegen from the connector registry and the `/v1/tool_calls` channel binding (13-02) — the golden task's tools are plain in-body functions.
- Any change to Stage-4 generation prompts, the judge, or Stage-5 security review (13-03); existing generated agents keep working on the native envelope path.
- Multi-agent routing, conversation orchestration, or persistence of history (Phase 14 owns the chat surface; this feature only shapes the kit's contract).
- Framework swap machinery beyond the seam itself (the no-framework fallback stays in `.planning/bakeoff-agent-framework/` as evidence, not shipped code).
- Streaming responses on the OpenAI-compatible surface, unless the framework requires them for non-streaming runs (it does not, per the bake-off).
- Any change to the gate, manifest semantics, capability render, or world-B invariants.
