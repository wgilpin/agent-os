# Quickstart: World-B Verification

Prove, in one command, that the deterministic gate physically prevents every manifest breach
regardless of agent code — and read each prevention from substrate-side evidence, not from the agent.

## Run the world-B bar (the "v2 done" gate)

```sh
# Deterministic, hermetic: no network, no model, no docker.
mix test test/agent_os/world_b_test.exs
```

A **green** run means all eight breach classes are prevented — the World-B bar is met (SC-011) and the
hard precondition for Phase 4 (generation) is satisfied. A **red** describe is a failing verification
(a defect against the originating Phase-3 chokepoint), and Phase 4 must not begin until it is green.

The eight `describe` blocks map 1:1 to the breach classes:

```
BC-1 exceed grants            BC-5 forge a trigger
BC-2 spoof recipient/method   BC-6 forge / self-grant an approval
BC-3 exfiltrate / no-bypass   BC-7 read the manifest
BC-4 bust the dollar cap      BC-8 hold a credential
```

## Run the physical sandbox backstop (separate, docker-dependent)

```sh
# Not part of the deterministic gate; proves the OS-level sandbox physically holds.
mix test --include docker test/agent_os/isolation_test.exs
```

This confirms network egress is disabled, the filesystem is read-only, and hostile web input is
sanitized — the physical facet of breach classes 3/7/8. It is excluded from the default run
(`test_helper.exs` sets `ExUnit.start(exclude: [:docker])`) and is **not** required for the world-B
verdict.

## Read a prevention from substrate evidence (the legibility check)

Each clause asserts on a substrate-owned surface, never on the agent. Examples:

- **Exceed grants (BC-1)** — feed `Gate.partition_batch/4` a hostile batch; assert each ungranted
  action returns `{:reject, :unknown_action}` and never reaches the injected `effector_fn`.
- **Spoof recipient (BC-2)** — assert `Gate.evaluate/4` returns `{:reject, :recipient_out_of_scope}`
  for an out-of-scope recipient, while the in-scope variant `:approve`s.
- **Bust the cap (BC-4)** — drive `InferenceBroker.complete/4` with an injected over-cap `provider_fn`;
  assert it meters its own dollars into `spend_ledger` and returns `{:breach, :spend}` regardless of any
  under-reported figure.
- **Forge a trigger (BC-5)** — emit a trigger-shaped string as agent output; assert zero fires; then
  `TriggerGateway.submit/1` the identical signal and assert exactly one fire (origin, not shape).
- **Read the manifest (BC-7)** — build the agent payload with `RunWorker.build_payload/2`; assert its
  keys are exactly `["items","state"]` and no manifest field is serialized.
- **Hold a credential (BC-8)** — call `CredentialProxy.with_credential/2`; assert the return is the
  closure result only, never the secret.

## What "done" looks like

- `mix test test/agent_os/world_b_test.exs` is green (all eight classes prevented).
- No production `lib/agent_os/` change was required (pure verification) — or, if a gap was found, it was
  fixed as a defect in the originating chokepoint and that fix is what turned the class green.
- `mix test` (full default suite), `mix format`, and Credo/Dialyzer remain clean.
