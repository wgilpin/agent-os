# Quickstart: Manifest Invisible to the Agent

This feature adds a contract test and two documentation notes — no runtime behavior. Here's how
to confirm it works and how to see it catch a regression.

## 1. Run the invariant test (green path)

```sh
mix test test/agent_os/boundary_test.exs
```

Expected: all assertions pass — the agent-bound payload is exactly `{state, items}`, the
container argv mounts nothing and excludes the manifest, and no mutating credential appears in
the env.

## 2. Watch it catch a deliberate leak (red path)

To convince yourself the test is real, temporarily make the substrate leak an envelope field —
for example, add `"grants" => manifest.grants` to the payload `RunWorker` builds, or add a
`-v .../manifests/discovery.md:...` mount to `Sandbox.build_argv/1`. Then:

```sh
mix test test/agent_os/boundary_test.exs
```

Expected: the test fails loudly, naming the leaked key/value/mount. Revert the change and it
passes again.

## 3. Read the invariant notes

The gate-only invariant is stated where a contributor would threaten it:

- `lib/agent_os/run_worker.ex` `@moduledoc` — the module that builds the agent-bound payload.
- `lib/agent_os/manifest.ex` `@moduledoc` — the module that owns/loads the manifest.

Each note states the manifest is gate-only and never crosses the boundary, and points to
`test/agent_os/boundary_test.exs`.

## 4. Full suite (no regressions)

```sh
mix test --exclude docker
```

Expected: the whole suite stays green; this feature touches no production code path beyond
`@moduledoc` text.
