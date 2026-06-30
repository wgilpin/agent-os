# Contract: Novel Agent Body Generator API

Defines the program interface for Stage 4 — synthesizing and writing the novel agent body.

## Public Elixir API

```elixir
defmodule AgentOS.Pipeline.Stage4 do
  alias AgentOS.Manifest
  alias AgentOS.Pipeline.Stage4.AgentBody

  @doc """
  Stage 4 entrypoint: synthesizes a novel Python/PydanticAI agent body from a confirmed
  manifest (whose `purpose` field supplies the confirmed purpose) and writes it to
  `agents/<agent_name>/{main.py,models.py}`.

  Routes the authoring LLM call through AgentOS.InferenceBroker. Never reads
  `judge_spec.json` or any Stage-3 artifact — the function's only domain inputs are
  `agent_name` and `manifest`, and the implementation never reads a judge-spec path.

  Verifies the synthesized body (path safety, typed-contract presence, no manifest/
  credential literal, no direct provider path, valid Python syntax) BEFORE writing; any
  guard failure or broker failure returns {:error, reason} and writes nothing.

  ## Options
    - `:run_token` - REQUIRED metered run token (registered with the broker).
    - `:model` - Authoring model name (defaults to `:agent_codegen_model` config).
    - `:spec_dir` - Base dir for the agents tree (defaults to `"agents"`).
    - `:provider_fn`, `:prices`, `:now` - forwarded to the broker (test seams).
  """
  @spec generate(String.t(), Manifest.t(), keyword()) :: {:ok, AgentBody.t()} | {:error, any()}
  def generate(agent_name, manifest, opts \\ [])
end
```

## Guard Conditions

1. **Input-Surface Guard (judge-blindness, FR-003)**:
   - `generate/3`'s signature carries no parameter or opt capable of expressing a judge spec,
     test case, or `judge_spec.json` path. The implementation never reads `judge_spec.json` or
     any file under the agent's directory other than the two files it writes.
2. **Path-Safety Guard (FR-005)**:
   - Every emitted file's path is a bare relative filename ending in `.py`, with no `/` and no
     `..` — preventing any write outside `agents/<agent_name>/`.
3. **Typed-Contract Guard (FR-004)**:
   - `main.py` must show evidence of reading one line of typed JSON from stdin (via a Pydantic
     model) and emitting typed JSON output — matching the existing port-workload shape.
4. **No-Manifest-Leak Guard (FR-006)**:
   - The emitted body must not contain the manifest's spend cap, any grant's
     connector/recipient/method as a literal, or a credential-shaped string.
5. **Single-Chokepoint Guard (FR-008, FR-009)**:
   - The emitted body must not reference a direct model-provider hostname or SDK, and any
     network I/O it performs must reference `INFERENCE_SOCKET`. The authoring call itself must
     go through `AgentOS.InferenceBroker.complete/2`.
6. **Syntax-Validity Guard (FR-011)**:
   - Each emitted `.py` file must parse as valid Python before any file is written.
7. **Fail-Closed Guard (FR-012)**:
   - If the authoring call returns a timeout, error, or `{:breach, :spend}`, or if any guard
     above fails, `generate/3` returns `{:error, reason}` and writes no file — no partial
     write, no fallback body.
8. **Budget/Metering Guard**:
   - `generate/3` must require a valid metered run token; if none is provided, or the spend cap
     is breached, the call fails safe with no write.

## Out of Scope for This Contract

- Running, evaluating, or deploying the emitted agent (no `run/2`-equivalent in this stage — that
  belongs to later pipeline stages, e.g. 04-09's deploy/run wiring and 04-06's judge `run/2`).
- Any change to `AgentOS.InferenceBroker`, the deterministic gate, or the manifest schema.
