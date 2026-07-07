# Quickstart: Run-Worker Transcript Migration

How to work on and verify this feature.

## What changes

- `lib/agent_os/run_worker.ex` — `execute_run/5` stops decoding `{"actions"}` and
  re-gating/re-executing; parses a typed `OutcomeRecord` from stdout and derives the
  run-log tally + breach decision from `ActionTranscript` and the `spend_ledger`.
- `lib/agent_os/outcome_record.ex` (new) — `OutcomeRecord` struct + `parse/1`.
- `test/fixtures/generation/generation.ex` — stub body prints an outcome record;
  `models.py` describes the outcome record only (no `actions`).
- `test/agent_os/run_supervisor_test.exs`, `test/agent_os/port_runner_test.exs` — migrated
  off the `actions` assertions.
- `test/agent_os/run_worker_transcript_test.exs` (new) — US1–US4 with seeded transcripts.

## TDD loop (Constitution III)

1. Write `run_worker_transcript_test.exs` first (RED): seed `action_transcript`,
   `spend_ledger`, `pending_approvals` stores; stub the agent command to print an outcome
   record to stdout; assert run-log tally / no-double-execution / breach / single park.
2. Add `OutcomeRecord` + rewrite `execute_run/5` until GREEN.
3. Migrate the two existing tests and the fixture; refactor.

## Seeding a run without a live model (Constitution IV)

- Use `agent_cmd`/`agent_args` (or a `PortRunner` stub) that echoes a fixed outcome-record
  line to stdout — no docker, no socket, no model.
- Pre-populate the transcript for the run token. Because `RunWorker` generates the token
  internally, either (a) inject it via an opt/seam the test controls, or (b) assert on the
  run log's derived counts by seeding the store the rail would have written. Prefer a test
  seam that lets the test set/observe the run token so the transcript can be pre-seeded
  deterministically.

## Verify

```sh
# Focused
mix test test/agent_os/run_worker_transcript_test.exs

# Migrated existing suites
mix test test/agent_os/run_supervisor_test.exs test/agent_os/port_runner_test.exs

# Full suite must be green (fix ALL failures, not just this feature's)
mix test

# Quality gates
mix format --check-formatted
mix credo
```

## Acceptance smoke checks (map to spec)

- **US1**: outcome record + transcript(2 granted,1 rejected) ⇒ run `:ok`, actions=2,
  rejected_count=1, not malformed.
- **US2**: granted effect in transcript ⇒ connector invoked zero extra times by the worker.
- **US3**: ledger at/over cap post-run ⇒ run recorded breached, breach policy applied.
- **US4**: one parked entry + one pending-approval already queued ⇒ run log shows 1 parked,
  queue still holds exactly 1 (no duplicate).
- **Malformed**: legacy `{"actions": []}` stdout ⇒ `:error`, `failure_cause`
  `"malformed_outcome"`.
