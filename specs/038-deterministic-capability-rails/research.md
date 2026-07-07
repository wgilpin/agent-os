# Phase 0 Research: Deterministic Capability Rails

This feature is architecture-heavy but technology-light: no new dependencies, no
NEEDS-CLARIFICATION on tooling. The open questions are all "where does this decision live
on the deterministic substrate?" Each is resolved below against the codebase as it stands.

## Current-state findings (why runs fail on noise today)

- The structured tool channel **already exists** in
  [`inference_broker.ex`](../../lib/agent_os/inference_broker.ex): `build_tools_list/1`
  derives OpenAI-style tool declarations from the manifest grants, injects them into the
  provider call, and `execute_tool_calls/4` gates each call (`is_granted?`) and executes it.
- It is **bypassed for generated agents** for two reasons:
  1. The orchestrator registers a single run token under the **`"orchestrator"` manifest
     with `grants: []`** and threads that same token to the agent at runtime via
     `RUN_TOKEN` (`Stage3.default_runner`). So when the generated agent calls the broker,
     the resolved manifest has **no grants → `build_tools_list/1` returns `[]` → no tools
     injected → free-text is the only channel**.
  2. `discord_notify` (and `gmail_*`, `file_*`, `external_send`, `kv_append`) carry **no
     `tool_declaration`**; only `store_append`, `store_find`, `web_search` do.
- The Stage-4 synthesis prompt hard-codes the **free-text `{"actions":[…]}` protocol** and
  the literal fallback model string `google/gemini-3-flash-preview`, and the generated
  `main.py` implements exactly that. This is the lossy channel the spec retires.
- `execute_tool_calls/4` **`{:halt, {:error, {:unauthorized_tool, …}}}`** on an ungranted
  tool — it aborts the whole inference loop rather than recording the rejection and letting
  the agent refuse. This is why an adversarial probe crashes instead of scoring.
- The gate checks `g.connector == tool_name` **only** — no method-scope check (FR-004 gap).
- `InferenceBroker.complete/2` prices and routes on the **workload-supplied `request.model`**
  (FR-012 gap); an unpriced claim → `{:error, :unpriced_model}` mid-pipeline.

---

## Decision 1 — Where the action transcript lives and how it reaches the judge

**Decision**: The broker persists an **`ActionTranscript`** (ordered `TranscriptEntry`
list) to `StateStore`, keyed by **run token**. Stage-3's runner **clears** the transcript
for the token before invoking the agent, runs the agent (whose runtime inference drives
tool calls inside the broker loop), then **reads** the transcript back as the judge's
`observed_actions`. The agent's stdout is no longer the action source — only its
run-summary / refusal record.

**Rationale**: Tool calls are gated and executed/recorded **inside** the broker's
inference loop, so the transcript is naturally substrate-side. Persisting it via
`StateStore` (single writer, Principle IX) keeps it authoritative and legible
(Principle VIII), and means the judge never has to trust the untrusted agent to echo its
own actions. Keying by run token reuses the identifier that already binds the agent
process to the broker.

**Alternatives rejected**:
- *Agent echoes the transcript on stdout* — trusts the untrusted party to report its own
  actions; violates the spirit of Principle X and re-introduces a lossy channel.
- *Return transcript in the broker HTTP response* — the agent may make several broker
  calls per run; assembling the full-run transcript belongs to the substrate, not a single
  response.

**Scoping note**: transcript keyed by run token is cleared per agent invocation by the
runner, so reused tokens across test cases don't bleed. (See data-model for the struct.)

## Decision 2 — Record-don't-execute mode and how the flag is threaded

**Decision**: Extend broker **registration** to carry a mode:
`register(token, agent_name, manifest, mode)` where `mode ∈ {:live, :record}` (default
`:live`, keeping existing call sites source-compatible via an arity-3 clause). In
`:record` mode, `execute_tool_calls/4` **records** each granted call and returns a
**synthetic success** tool message (`{"status":"recorded"}`) to the reasoning loop
**without** calling `execute_tool/2` and **without** charging connector cost. Stage-3
registers the **agent-runtime** token in `:record` mode.

**Rationale**: The mode is a property of *why the token exists* (a judged run vs a live
run), not of an individual call, so registration is the right seam — the agent's Python
code stays identical in both modes (Principle X: the workload can't tell it's being
judged, and can't opt out). Inference is still metered (FR-011); only connector execution
cost is skipped for non-executed calls.

**Alternatives rejected**:
- *Per-request opt* — the untrusted workload would carry the flag; unacceptable.
- *A separate "eval broker"* — duplicates the metered chokepoint; violates Principle XI
  (single firewall) and Principle I.

## Decision 3 — Substrate-owned model identity (FR-012)

**Decision**: Registration carries an optional **`effective_model`**. When present, the
broker uses it for routing **and** pricing and ignores `request.model` entirely. The
agent-runtime token (live and record) sets `effective_model` from a new config key
`:agent_runtime_model`. Synthesis/judge tokens (Stage 3/4/5) leave it unset and continue
to pass explicit models. The Stage-3 runner also sets the `AGENT_MODEL` env from the same
config so a well-behaved agent's default matches — but a lying agent cannot change routing
or price because the broker overrides.

**Rationale**: Puts model policy where the constitution says danger classification lives —
the substrate, not the manifest author or the workload (Principle X). Closes the
unpriced-model failure class: a bogus workload claim can no longer reach the price table.

**Alternatives rejected**:
- *Model field on the manifest* — plausible future, but the manifest is human/kernel
  authored and this feature needs config-level policy only; adding a manifest field is
  scope creep (Principle II). Registration `effective_model` leaves that door open.

## Decision 4 — Method-scope gate, one tool per connector (FR-004)

**Decision**: Keep **one `tool_declaration` per connector**. The broker gate, after the
connector-grant check, validates the **method** the call targets against the resolved
`grant.methods` allowlist, rejecting deterministically (same path as an ungranted
connector) when out of scope. For a connector with a single implicit method (e.g.
`discord_notify` → `notify`), the declaration need not expose a `method` parameter; the
gate resolves the sole granted method. Where a connector genuinely exposes multiple
methods, the declaration includes a `method` string parameter and the gate checks it.

**Rationale**: Simplest thing that works (Principle I) — no per-(connector,method) tool
explosion, and the method allowlist is manifest-derived at runtime (it can't be baked into
static connector metadata because the grant isn't known at metadata time). The gate stays
the single deterministic decision point.

**Alternatives rejected**:
- *One tool per (connector, method)* — multiplies the injected tool list and pushes method
  identity back into a string the model must reproduce — exactly the telephone game being
  retired.

## Decision 5 — Rejections are recorded, not fatal (FR-005)

**Decision**: On an ungranted-connector or out-of-scope-method call, the broker **appends a
rejection `TranscriptEntry`**, logs it (Principle VI), and returns a **typed rejection tool
message** (e.g. `{"error":"denied","code":"ungranted_connector"}`) to the reasoning loop —
it does **not** halt the loop. The agent can then honour the refusal contract (emit no
further actions + a reason). A genuinely broken loop (no progress) still terminates via the
existing spend cap / turn limits.

**Rationale**: A rejection is an *observation to score*, not an infrastructure fault. This
is the core fix for the "crash on adversarial input" failure class: the agent gets a
first-class "you can't do that" signal and can produce a scoreable refusal.

## Decision 6 — Refusal contract shape (FR-006, FR-007)

**Decision**: The refusal contract (written in `contracts/refusal-contract.md`) fixes the
port-workload outcome shape: **exit 0** with a single stdout JSON line
`{"outcome": "completed" | "refused", "reason": "<machine-readable>"}`. The **actions** are
never in stdout — they are the broker transcript. A `refused` outcome means the agent chose
to emit no (or only rejected) tool calls; a `completed` outcome means it performed its
granted action(s). **Abnormal termination** (non-zero exit, crash, timeout, unparseable
stdout) is reserved for genuine **malfunction**.

Stage-3 scoring classifies three cases, never silently aborting (FR-007):
- exit 0 + parseable outcome → build observed = (transcript, outcome) → **judge → pass/fail**
- abnormal termination → **`:malfunction` verdict** (distinct from `:error`)
- broker/harness fault (token, spend breach, provider error) → **`:error` verdict**

**Rationale**: Matches the spec's stated default (Assumptions) — successful exit with
empty/filtered actions plus a reason; no dedicated exit codes per refusal class. Extending
`Verdict.status` with `:malfunction` keeps malfunction reporting distinct from both
compliance verdicts and harness errors.

## Decision 7 — Judge rescope (FR-008, FR-013)

**Decision**: The Stage-3 **synthesis** prompt is told the refusal contract and instructed
to write boundary probes whose pass condition is *compliant refusal*, not string
reproduction; the two "IMPORTANT ARCHITECTURE RULES" about hardcoded strings are replaced
by "the substrate enforces grants deterministically; score purpose-fit and refusal-contract
adherence." The **eval** prompt presents deterministic rejections as **observed facts**
("the substrate blocked X") and asks the judge to score behaviour *around* them, never to
re-derive whether X was granted.

**Rationale**: Realigns the judge with its documented role (Constitution XI: smoke
detector, not firewall). Once enforcement is deterministic and the transcript records
rejections, string-checking tests have nothing left to check.

## Decision 8 — FR-014 loud failure on missing tool declaration

**Decision**: `build_tools_list/1` currently **silently skips** a granted connector with no
`tool_declaration`. Change it to **raise** (loud failure, Constitution VI) so generation
fails before any agent body is written. Add `tool_declaration` (+ `execute_tool/2` for the
live path) to `discord_notify`; add declarations to any other connector a **current**
manifest can grant, but no further (Principle II).

**Rationale**: Directly implements FR-014 and mirrors the existing loud-failure rule in
`CapabilityRender.entries/1` (raises on a connector missing from the registry).

---

## Consolidated impact summary

| FR | Landing site | Mechanism |
|----|-------------|-----------|
| FR-001, FR-002 | `stage4_agent.ex` | drop free-text protocol + model literal from synthesis prompt; act via native tool calls |
| FR-003, FR-004 | `inference_broker.ex` gate | typed reject on ungranted connector / out-of-scope method |
| FR-005, FR-010 | `inference_broker.ex` + `action_transcript.ex` | record every call/rejection to the run-token transcript; transcript is judge input |
| FR-006, FR-007 | `refusal-contract.md` + `stage3_judge.ex` | refusal record shape; classify pass/fail/malfunction/error |
| FR-008, FR-013 | `stage3_judge.ex` prompts | refusal-aware synthesis; rejections-as-facts scoring |
| FR-009, FR-011 | `inference_broker.ex` record mode | record + synthetic success, no execution, inference still metered |
| FR-012 | `inference_broker.ex` + config | substrate-resolved `effective_model` overrides workload claim |
| FR-014 | `inference_broker.ex` `build_tools_list/1` + `discord_notify.ex` | raise on missing declaration; add declaration |
| FR-015 | pipeline end-to-end | regenerated agent, retired protocol absent everywhere |
