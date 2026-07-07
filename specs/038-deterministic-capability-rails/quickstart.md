# Quickstart: Deterministic Capability Rails

How to exercise the feature end-to-end (the hello-world Discord scenario) and verify each
success criterion. All commands run from the repo root. **No live model calls** — the
pipeline runs through deterministic `provider_fn` / `runner_fn` seams in tests, and against
the metered broker chokepoint otherwise.

## Prerequisites

- `mix deps.get` and the Python workload venv (`uv`) as per the project README.
- Elixir toolchain (`mix`, `iex`), Python 3.12 for the port workload.

## Run the control-plane tests

```bash
mix test test/agent_os/inference_broker_test.exs \
         test/agent_os/action_transcript_test.exs \
         test/agent_os/pipeline/stage3_judge_test.exs \
         test/agent_os/pipeline/stage4_agent_test.exs \
         test/agent_os/connector/discord_notify_test.exs \
         test/agent_os/world_b_generated_test.exs
```

Then the full suite (Constitution: fix ALL failing tests, not just this feature's):

```bash
mix test
mix format --check-formatted && mix credo --strict
```

## Verify each Success Criterion

### SC-001 — 3 consecutive clean end-to-end runs
Run the orchestrator against the hello-world Discord spec 3× (via the pipeline entrypoint /
its test harness). Expect `outcome: :deployed` each time, with **no** stop reason in the
retired noise classes (identifier hallucination, workload model string, undefined refusal).

### SC-002 — every ungranted request blocked before effect
With a stubbed runtime `provider_fn` that emits a tool call for an **ungranted** connector
and for a **granted connector + ungranted method**, assert the broker returns a typed
rejection, the ActionTranscript has a `:rejected` entry with the right `reason_code`, and
no connector executed.

### SC-003 — zero external deliveries during evaluation
Register the discord webhook transport as a monitored sink. Run the full Stage-3 evaluation
in `:record` mode. Assert the sink received **zero** messages and every granted call in the
transcript carries the synthetic `{"status":"recorded"}` result.

### SC-004 — boundary probes yield pass/fail, never infra-error
Run the synthesized boundary probes. Assert each test's `Verdict.status ∈ {:pass, :fail,
:malfunction}` and that a probe requesting ungranted activity, met with a compliant
`refused` record, scores `:pass`. Assert **no** `:error` verdict is produced by agent
refusal behaviour.

### SC-005 — no manifest/model strings in generated artifacts
Scan the regenerated `agents/<hello-world-discord>/{main.py,models.py}` and the Stage-4
synthesis prompt: assert none of the manifest grant literals (`discord_notify`, `notify`,
recipients), the spend cap, or a model identifier string appear.

```bash
# illustrative — the automated check lives in stage4_agent_test.exs
! grep -RInE 'discord_notify|"notify"|gemini-3-flash-preview' \
    agents/send_a_hello_world_notification_*/main.py agents/send_a_hello_world_notification_*/models.py
```

### SC-006 — bogus model claim is inert
With an agent-runtime token registered with `effective_model` set and a stubbed workload
claiming a bogus/unpriced model, assert the run proceeds on the substrate-configured model,
pricing uses that model, and no `:unpriced_model` error occurs.

## What "done" looks like

- The free-text action protocol appears **nowhere**: not in the Stage-4 synthesis prompt,
  not in any generated body (grep clean).
- `discord_notify` has a `tool_declaration`; a granted connector without one fails
  generation loudly.
- The broker records a transcript per run token, rejects ungranted connectors **and**
  out-of-scope methods, records rather than aborts, and runs a record-don't-execute mode.
- The judge scores purpose-fit + refusal-contract adherence; `Verdict.status` distinguishes
  `:malfunction` from `:error`.
- `mix test`, `mix format --check-formatted`, `mix credo --strict` all clean.
