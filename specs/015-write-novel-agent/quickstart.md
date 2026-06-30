# Quickstart: Stage 4 Write the Novel Agent Body

## What this stage does

Given a confirmed purpose (carried on `manifest.purpose`) and the machine-written manifest Stage 2
emitted, produce a brand-new `agents/<agent_name>/main.py` + `agents/<agent_name>/models.py` —
written specifically for that purpose, never reading the Stage-3 judge spec, never embedding the
manifest or a model credential into the emitted code.

## Minimal usage (from IEx / a pipeline orchestrator)

```elixir
manifest = AgentOS.Manifest.Projection.project(elicited_spec)  # Stage 2 output, confirmed: true

run_token = "..."  # registered with AgentOS.InferenceBroker beforehand
AgentOS.InferenceBroker.register(run_token, "recruiter_reply_agent", manifest)

case AgentOS.Pipeline.Stage4.generate("recruiter_reply_agent", manifest, run_token: run_token) do
  {:ok, %AgentOS.Pipeline.Stage4.AgentBody{files: files}} ->
    # agents/recruiter_reply_agent/main.py and models.py now exist on disk
    Enum.each(files, fn f -> IO.puts("wrote #{f.path}") end)

  {:error, reason} ->
    # No files were written. Inspect `reason` (see contracts/agent-generator-api.md's guard list).
    Logger.error("Stage 4 generation failed: #{inspect(reason)}")
end
```

## Testing locally (no live model call — Constitution IV)

```elixir
# test/agent_os/pipeline/stage4_agent_test.exs
stub_provider = fn _request ->
  {:ok,
   %{
     completion:
       Jason.encode!(%{
         files: [
           %{path: "main.py", content: "<typed stdin/stdout contract source>"},
           %{path: "models.py", content: "<pydantic models source>"}
         ]
       })
   }}
end

AgentOS.Pipeline.Stage4.generate("test_agent", manifest,
  run_token: "tok",
  provider_fn: stub_provider
)
```

## Verifying the judge-blindness property (SC-004)

```elixir
# Place a judge_spec.json fixture at agents/test_agent/judge_spec.json BEFORE calling generate/3.
# Assert the result with the same stub provider_fn is identical whether the file exists or not —
# proving presence-on-disk does not change synthesis output (Stage 4 never reads that path).
```

## What you will NOT see from this stage

- No `judge_spec.json` read or written.
- No `data/judge_results.term`-style StateStore entry (this stage produces a file artifact, not a
  verdict — see [data-model.md](./data-model.md)).
- No deploy, no gate change, no security review, no agent execution.
