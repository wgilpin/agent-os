# Contract: Deterministic Agent Body (synthesis contract A)

**Boundary**: Stage 4 synthesis output → sandboxed runtime (PortRunner) → substrate.
This is the contract the Stage-4 deterministic prompt instructs and the guards +
judge verify. The inference contract (B) is today's broker-completion body,
unchanged.

## Runtime behavior (`main.py`)

1. Read exactly ONE line of JSON from stdin — the trigger payload. **Treat it as
   opaque data.** It is never interpolated into any instruction-interpreting
   context; there is no LLM slot for it to steer. It MUST NOT change which tool
   calls are submitted (injection-immunity by construction: adversarial payload →
   byte-identical submission).
2. Submit the hard-coded tool call(s) to the substrate via a single POST to
   `/v1/tool_calls` on `INFERENCE_SOCKET` (reference implementation supplied
   verbatim in the synthesis prompt, mirroring the existing broker-call reference
   pattern), carrying `RUN_TOKEN`.
3. Derive the terminal outcome from the per-call dispositions in the response, in
   this priority order (never "completed" unless every disposition is "executed"):
   - any error → `{"outcome": "error", "reason": <content>}`
   - any rejected → `{"outcome": "rejected", "reason": <feedback>}`
   - any parked → `{"outcome": "parked", "reason": "pending approval"}`
   - all executed → `{"outcome": "completed", "reason": ...}`
   A non-200 channel response raises (exit non-zero) — loud, never a false success.
   The outcome record has exactly two keys: "outcome" and "reason". The transcript
   remains the source of truth; the outcome record is a summary.
4. Argument shape is statically guarded: Stage 4 embeds the granted tools' declared
   parameter schemas in the synthesis prompt, and `guard_deterministic_args` rejects
   a body that names a granted tool without its required parameter names (record-mode
   judging cannot see argument drift; this deterministic check can).
4. Print the outcome record as a single line of JSON to stdout; exit 0.
   Unexpected exceptions exit non-zero (never a silent success).

`models.py`: Pydantic models for the outcome record (and submission payload if the
body models it) — the typed-contract guard is unchanged across modes.

## What the body may and may not contain

Allowed (mode-aware relaxation of `guard_no_manifest_leak`):
- Granted connector **tool names** and granted **method names** — these are the
  registry's public tool-declaration vocabulary, already exposed to models on the
  inference path. Naming one confers nothing; the rail gates every call.
- Tool-declaration argument fields with hard-coded values (e.g. `text`).

Forbidden in EVERY mode (guards unchanged):
- Recipients / allowlists, the spend cap, any credential-shaped string, any other
  manifest literal.
- Direct model-provider hosts/SDKs; any non-UDS network I/O (`requests`, `urllib`,
  `httpx`, `AF_INET`, …).
- Reading any env var other than `INFERENCE_SOCKET` and `RUN_TOKEN`
  (a deterministic body does not need `AGENT_MODEL` and must not require it).
- **Any call to `/v1/inference`** — a deterministic body makes zero inference
  requests; runtime inference spend for such an agent is zero by construction.

## Environment provided by the substrate

| Var | Provided | Used |
|-----|----------|------|
| `RUN_TOKEN` | yes | in the submission body |
| `INFERENCE_SOCKET` | yes | UDS path for `/v1/tool_calls` |
| `AGENT_MODEL` | may be set by the harness | ignored by deterministic bodies |

## Verification hooks

- Stage-4 guards: typed contract, path safety, Python syntax, no direct provider —
  shared with mode B; manifest-leak guard applies the mode-aware ruleset above.
- Stage-3 judge (deterministic branch): asserts the fixed effect appears on the
  transcript for benign AND adversarial inputs (identical behavior), and that
  nothing outside the grant set appears as `:granted`.
- E2E fixture test: adversarial stdin → submission bytes identical to benign case;
  transcript shows the single `:granted` entry; spend ledger shows connector cost
  only.
