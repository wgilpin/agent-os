# Quickstart: E2E Generation Thread + World-B on a Generated Agent

Prerequisites: repo on branch `027-e2e-generation-thread`, `mix deps.get` done. All steps
run offline — stages use injected stubs; no live model calls (Constitution IV).

## 1. Run the full test suite

```bash
mix test
```

Expect the existing suite (currently 258 passing) plus the new orchestrator and
world-B-generated tests to pass. The pre-existing `world_b_test.exs` must remain green and
unchanged.

## 2. Drive the recruiter thread end-to-end (in IEx)

```bash
iex -S mix
```

```elixir
# Load the confirmed "reply to recruiter emails" spec fixture (machine-written path).
spec = AgentOS.Fixtures.Generation.recruiter_confirmed_spec()

# Run the whole pipeline human-out-of-the-loop, default v3-launch review mode.
{result, run} = AgentOS.Pipeline.Orchestrator.run(spec, :always_review)

run.outcome        #=> :deployed | :blocked | :stopped
run.judge_verdict  #=> :pass
run.security_verdict #=> :pass
run.provenance     #=> :reviewed_human (blocked for the semantic human check under default mode)
run.stages         #=> [%{stage: :manifest, status: :ok}, ...] in execution order
```

Read the same facts without asking the agent (legibility):

```elixir
AgentOS.StateStore.snapshot("pipeline_runs")["recruiter"]   # the PipelineRun
AgentOS.Inventory.render()                                   # judge + security verdicts + provenance
# data/run_log.md                                            # one appended human-readable line
```

## 3. Prove a red path never deploys

```elixir
# Force a failing security review via stub; confirm no deploy.
{:error, run} =
  AgentOS.Pipeline.Orchestrator.run(spec, :always_review,
    stage5_provider_fn: fn _model, _msgs, _secret -> AgentOS.Fixtures.Generation.security_fail() end
  )

run.outcome     #=> :stopped
run.stopped_at  #=> :security_review
# No agent deployed; the inventory attributes the stop to the security review.
```

## 4. Run world-B against the generated agent (the headline acceptance)

```bash
mix test test/agent_os/world_b_generated_test.exs
```

Every breach case (BC-1…BC-7) must be denied by the gate against a machine-written
manifest + machine-written body. To confirm no case was dropped relative to the
hand-written suite:

```bash
grep -c 'describe "BC-' test/agent_os/world_b_test.exs
grep -c 'describe "BC-' test/agent_os/world_b_generated_test.exs   # must match
```

## 5. Gate/envelope/review-mode untouched (scope guard)

```bash
mix test test/agent_os/world_b_test.exs test/agent_os/provisioner_test.exs
```

These pre-existing suites must pass unchanged — proof that this feature added no stage
logic and altered no gate, envelope, or review-mode semantics (SC-007).
