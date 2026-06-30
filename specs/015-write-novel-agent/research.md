# Research: Stage 4 Write the Novel Agent Body

This document records the design decisions for `AgentOS.Pipeline.Stage4`, the synthesis module that
writes a novel Python/PydanticAI agent body from a confirmed purpose and a machine-written manifest.
It deliberately mirrors `AgentOS.Pipeline.Stage3` (`lib/agent_os/pipeline/stage3_judge.ex`) wherever
the same architectural problem already has an established answer, and only departs where Stage 4's
job (emit code, not emit a test spec) genuinely differs.

## Judge-Blindness: How "MUST NOT read judge_spec.json" Is Enforced

**Decision**: Two layers, not one.
1. **Input-surface guard (process isolation).** `Stage4.generate/3`'s only domain parameters are
   `agent_name` and `manifest :: AgentOS.Manifest.t()`. There is no `opts` key through which a judge
   spec, test case, or `judge_spec.json` path can be threaded in — unlike Stage 3's
   `@forbidden_context_keys` list (which *rejects* a transcript that could technically be passed),
   Stage 4 simply has no parameter shape capable of carrying judge content at all. The function
   signature itself is the guard.
2. **Filesystem guard (defense in depth).** Stage 4's implementation never calls `File.read` (or any
   path-construction helper) against `judge_spec.json` or any path under the agent's directory other
   than the two files it writes. This is enforced by code review / static check at task-review time
   and by a test that runs synthesis in an `agents/<agent_name>/` directory where a `judge_spec.json`
   fixture already exists, asserting the synthesis result is byte-identical (given a fixed stub
   `provider_fn`) whether or not that file is present — directly testing SC-004.

**Rationale**: A keyword-list filter (Stage 3's approach) makes sense when the function legitimately
accepts an open-ended `opts` bag for test seams (`:provider_fn`, `:now`) and must reject a few
specific dangerous keys. Stage 4 has the same test-seam opts, but "judge spec" is not a concept its
options should ever need to express, so the simpler and stronger guard is "the contract has no slot
for it" plus a behavioral test proving presence-on-disk doesn't leak in.

**Alternatives considered**: Mirroring Stage 3's `@forbidden_context_keys` exactly (add
`:judge_spec`, `:test_spec` to a blocklist) — rejected as strictly weaker than "no slot exists," and
it would imply judge content is a valid-but-forbidden input shape, which is the wrong mental model:
it isn't an input at all.

## Synthesis Prompt Design

**Decision**: A system/user message pair built from `agent_name`, `manifest.purpose`, and
`AgentOS.CapabilityRender.render(manifest)` (the existing deterministic capability-render used by
Stage 3 and the 04-01 consent view) — same rendering function, reused for the same reason: it is
already the canonical, drift-free way to describe "what this manifest grants" in natural language for
prompt context.

The system message instructs the model to:
- Write **two files**: `main.py` (entry point) and `models.py` (Pydantic input/output models),
  matching the exact shape of `agents/discovery/main.py` / `agents/discovery/models.py`: read one
  line of JSON from stdin, parse it into a typed Pydantic model, reason over it, and emit a JSON list
  of typed proposed actions to stdout.
- Reach inference, if needed, **only** by reproducing the existing
  `call_inference_broker`-equivalent pattern (connect to the Unix domain socket at
  `os.environ["INFERENCE_SOCKET"]`, authenticate with `os.environ["RUN_TOKEN"]`, POST to
  `/v1/inference`) — the prompt includes that exact helper as a copy-pasteable reference snippet
  (sourced from `agents/discovery/main.py`) so the model reproduces a known-good chokepoint call
  rather than inventing its own transport.
- **Never** read, embed, or hard-code the manifest, any grant detail, a spend cap, a credential, or
  any environment variable other than `INFERENCE_SOCKET` and `RUN_TOKEN`. The manifest's rendered
  text is given only as *prose context describing the purpose's scope*, explicitly labelled
  "context, not data to embed."

The user message gives the purpose and the rendered grant summary, and explicitly states the
contract for the model's response: a single JSON object,
`{"files": [{"path": "main.py", "content": "..."}, {"path": "models.py", "content": "..."}]}`.

**Rationale**: Reusing `CapabilityRender.render/1` keeps the prompt's description of "what this
agent may do" perfectly in sync with the actual grants (it cannot drift, since it is the same
mechanical lookup Stage 3 and the consent view already use) without exposing the raw manifest struct
to anything downstream of the prompt-build step. Supplying the broker-call snippet verbatim
dramatically increases the odds the model reproduces the existing UDS chokepoint protocol correctly
instead of synthesizing a subtly-wrong one — this is showing the model the *pattern* the substrate
already enforces, not handing it a credential.

**Alternatives considered**: Free-form "write an agent for this purpose" with no reference snippet —
rejected, too likely to produce inference code that doesn't match the existing UDS protocol exactly,
which would then fail at runtime in a later stage rather than being caught here. A single combined
`main.py` with inline models — rejected in favor of matching the existing two-file
(`main.py`/`models.py`) convention exactly, since `agents/discovery` already establishes that split
and FR-004 ties the contract to "matching the existing port-workload shape."

## Output Schema and Parsing

**Decision**: `AgentOS.Pipeline.Stage4.GeneratedFile` (`%{path: String.t(), content: String.t()}`)
and `AgentOS.Pipeline.Stage4.AgentBody` (`%{agent_name: String.t(), purpose: String.t(), files:
[GeneratedFile.t()]}`), both `@enforce_keys` structs with `@type`, parsed from the broker's
`completion` field the same way `Stage3.parse_tests/1` parses its `{"tests": [...]}` shape:
`Jason.decode/1` then pattern-match each file's `path`/`content` as binaries, rejecting (not raising)
on any malformed entry.

**Rationale**: Matches Stage 3's established type-and-parse pattern (Constitution V), keeps the
public return type strongly typed end-to-end, and keeps "malformed model output" a normal
`{:error, :invalid_synthesis_output}` branch rather than a runtime exception — consistent with
Stage 3's `parse_tests/1` failure mode.

## Static Guards Before Write (FR-006, FR-008, FR-011)

**Decision**: Four guards run over the parsed `AgentBody`, each able to fail the whole generation
(no partial write):

1. **Path safety.** Every `GeneratedFile.path` must be a bare relative filename with no `/`, no `..`,
   and must end in `.py`. Prevents the synthesis output from ever being able to name a path outside
   `agents/<agent_name>/` or shadow an unrelated file.
2. **Contract presence.** `main.py`'s content must contain evidence of the typed stdin/stdout
   contract: an import of `pydantic` (or `BaseModel`), a read from `sys.stdin`, and a `json` dump/
   print to stdout. This is a textual/regex check, not an AST-semantic proof — it is a smoke
   detector matching FR-011's "verify... before emitting," not an adversarial code review (that is
   the explicit job of the security-review stage, 04-08, per the spec's Assumptions section).
3. **No manifest/credential leakage.** The concatenated content of all files must not contain: the
   manifest's `spend.cap` value rendered as a literal, any grant's `connector`/recipient/method
   string rendered as a literal, or any of a small set of credential-shaped patterns (e.g.
   `api_key\s*=\s*["']`, `Authorization:\s*Bearer\s+[A-Za-z0-9]`). This directly checks FR-006.
4. **No direct provider path.** The concatenated content must not contain a known model-provider
   hostname or SDK import (e.g. `openai`, `anthropic`, `generativelanguage.googleapis.com`,
   `api.openai.com`) and, if it performs network I/O at all, that I/O must reference
   `INFERENCE_SOCKET`. This directly checks FR-008/FR-009's "no second provider path."
5. **Python syntax validity.** Each `.py` file's content must parse as valid Python. Implemented by
   shelling out to `python3 -c "import ast,sys; ast.parse(sys.stdin.read())"` for each file via the
   existing `AgentOS.PortRunner`-adjacent process-spawn pattern — this is a pure parse, not an
   execution of the generated logic, so it does not run untrusted code; it only confirms the
   generated text is syntactically Python. (Listed last because it is the only guard requiring a
   subprocess; the four content guards above run first and are pure Elixir string checks.)

Any guard failure returns a guard-specific `{:error, reason}` and the function returns before any
`File.write!/2` call — satisfying FR-012's "no partial write."

**Rationale**: This is deliberately a *structural* checklist, not a semantic security review — the
spec's own Assumptions section draws that line and assigns deep adversarial review to 04-08. The
guards chosen are exactly the things the spec's FRs make non-negotiable (typed contract, no
manifest/credential leak, no direct provider, must parse) and nothing more, per Constitution II
(Explicit Scope Control).

**Alternatives considered**: Running the generated agent in the sandbox as part of validation (i.e.
actually executing `main.py` once) — rejected explicitly by the spec ("MUST NOT run... the agent
here") and by Constitution XI (running generated code is exactly what the deterministic gate, not
this stage, must mediate). An LLM-based "does this code look safe" self-check — rejected as
redundant with 04-08 and as adding a second probabilistic judgement where a deterministic one
suffices, against Constitution XI's smoke-detector-vs-firewall framing.

## Single Inference Chokepoint, Both Ways

**Decision**: The *authoring* call (Stage 4 generating code) uses `InferenceBroker.complete/2` with
a required `:run_token`, identical to Stage 3's `generate/3`. The *emitted body's own* runtime
inference calls (if the agent needs them) are not made by Stage 4 at all — they are Python source
text Stage 4 writes, reproducing the `INFERENCE_SOCKET`/`RUN_TOKEN` UDS pattern from
`agents/discovery/main.py` (see "Synthesis Prompt Design" above), checked structurally by guard 4.

**Rationale**: This is the same chokepoint-discipline Stage 3 already follows for its own authoring
call; the only new piece is verifying (not just hoping) that the *generated* code also reproduces
the pattern, which is guard 4's job.

## Write Target and Atomicity

**Decision**: `spec_dir` option defaulting to `"agents"` (matching Stage 3's `default_runner/3` and
`write_spec/3` convention), writing to `Path.join([spec_dir, agent_name, "main.py"])` and
`Path.join([spec_dir, agent_name, "models.py"])`. Files are written only after all guards pass; if
any per-file write fails partway, the function returns `{:error, reason}` (logged per Constitution
VI) — a genuine torn-write on local-disk `File.write!/2` failure is treated as already-fatal
infrastructure failure, the same posture `Stage3.write_spec/3` takes for `judge_spec.json`.

**Rationale**: Consistency with the one existing precedent (`Stage3.write_spec/3`) for "the pipeline
writes a generated artifact under `agents/<agent_name>/`." No new directory-creation or
locking mechanism is needed beyond `File.mkdir_p!/1`, since each agent name is provisioned once per
generation and nothing else writes to that path concurrently (Constitution IX: single-writer
discipline is preserved because Stage 4 is the only writer of these two files, and it runs to
completion before any later pipeline stage reads them).
