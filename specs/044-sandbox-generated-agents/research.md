# Phase 0 Research — Sandbox Generated Agents

All unknowns from the Technical Context resolved. No `NEEDS CLARIFICATION` remain.

## D1 — Generated-agent runtime image: dedicated & generic, code mounted not baked

- **Decision**: Build one generic image `agent-generated:dev` from a new
  `agents/generated.Dockerfile`. It bakes the interpreter + venv dependencies
  (`uv sync --frozen --no-dev`, the same layer the discovery image uses) but does **not**
  `COPY agents/` and sets **no** agent-specific `ENTRYPOINT`. The specific generated body
  arrives at runtime via a read-only bind mount of `agents/<name>/`, and `run_worker`
  overrides `--entrypoint /app/.venv/bin/python` with `cmd_args ["/app/agents/<name>/main.py"]`.
- **Rationale**:
  - FR-002 requires a runtime image carrying the interpreter + bundled deps so no host
    interpreter is used. Baking deps satisfies this; the deps set is exactly
    `pyproject.toml` (`pydantic`, `google-genai`).
  - FR-003 requires the agent's code mounted **read-only** — so code must be a mount, not a
    baked layer. Not baking code also keeps the image agent-agnostic (Constitution IX): one
    image runs any generated body.
  - Roadmap 11-01 states this explicitly: "build a generated-agent runtime image (venv deps
    baked in, replacing the host `.venv/bin/python` resolution), mount `agents/<name>/`
    read-only."
- **Alternatives rejected**:
  - *Reuse `agent-discovery:dev` for generated agents.* It already has deps + a baked
    `agents/` copy; the read-only mount would shadow `/app/agents/<name>`. Rejected: it bakes
    the config agent's code into the image generated bodies run in (leak + noise), and FR-002
    reads as a dedicated image. Marginal.
  - *Per-generated-agent image (bake each body).* Rejected: violates Simplicity — an
    image build per generated agent, and code-in-image is not read-only-mountable, defeating
    FR-003's "cannot modify its own body" property.

## D2 — Import semantics survive the mount

- **Decision**: Mount at container path `/app/agents/<name>` (`:ro`) and invoke
  `python /app/agents/<name>/main.py`. Keep `PYTHONPATH=/app` and `PYTHONUNBUFFERED=1` in the
  image env.
- **Rationale**: Generated bodies use **bare** imports — the sampled body does
  `from models import OutcomeRecord`. When CPython runs `python /path/main.py` it prepends the
  script's directory to `sys.path[0]`, so the mounted leaf directory alone resolves
  `models`. No `__init__.py` package tree is needed. (The discovery agent uses the fuller
  `from agents.discovery.models import …` + a `sys.path.insert` and is unaffected — it keeps
  its baked-code image.)
- **Verification (quickstart)**: run the sampled generated agent
  (`get_the_local_time…discord_channel`) through the sandbox and confirm its `from models import`
  resolves and it reaches the broker over the UDS.
- **Alternative rejected**: rewrite generated bodies to package-qualified imports + mount the
  whole `agents/` tree. Rejected: broader mount surface, changes the generator's output
  contract, unnecessary given `sys.path[0]` behaviour.

## D3 — Replace the `cmd == "docker"` discriminator with config-agent identity

- **Decision**: Inside `execute_run/6`, stop using `cmd == "docker"` to decide (a) whether to
  load+sanitize bookmarks and (b) whether to build the full `{state, items}` payload vs the
  `{roster}`+`trigger_input` payload. Thread a `config_agent?` boolean (`agent_name ==
  Path.basename(cfg.manifest_path, ".md")`) and branch on that instead.
- **Rationale**: Today `cmd == "docker"` is a proxy for "is the config agent," because only the
  config agent ran under docker. Once generated agents also run under docker, that proxy
  breaks and would hand a generated agent the config agent's bookmark payload — a correctness
  regression and a boundary leak. The config agent is the substrate fixture; keying on its
  identity is the honest discriminator.
- **Alternative rejected**: keep `cmd == "docker"` and special-case the config image name.
  Rejected: couples payload shape to an image string; fragile.

## D4 — Loud failure for missing image / unavailable runtime / unmountable code (FR-009)

- **Decision**: Add a **pre-flight** in the generated-agent (and config) docker branch, before
  `PortRunner.run`:
  1. `File.dir?(Path.expand("agents/<name>"))` — false ⇒ record `failure_cause:
     "code_unmountable"`, log `:error`, return `{:error, :code_unmountable}`.
  2. `System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true)` — nonzero ⇒
     classify from output: "Cannot connect to the Docker daemon" ⇒ `runtime_unavailable`,
     otherwise `image_unavailable`. Log `:error`, record the cause, return `{:error, cause}`.
  Crucially the direct-python branch is **deleted**, so there is structurally no fallback path:
  a failed pre-flight ends the run loudly.
- **Rationale**: `PortRunner` discards the child's stderr and both failure modes surface as
  docker exit 125, so parsing the run's exit cannot distinguish them — a pre-flight is the
  simplest place to get a diagnosable cause (Constitution VI, FR-009, SC-005). Containment
  failures at runtime (read/write/network denied) already surface as a non-zero container exit
  the run-log records with `failure_cause` (proven for the config image in `isolation_test`).
- **Alternative rejected**: capture child stderr through the port wrapper and post-classify.
  Rejected: larger change to `port_wrapper.sh`/`PortRunner` for no extra signal a two-line
  pre-flight gives.

## D5 — Delete the bypass, keep the override (FR-005 + FR-006)

- **Decision**: Remove the `run_worker.ex` block that injects
  `agent_cmd: python_bin(), agent_args: ["agents/<name>/main.py"]` for non-config agents.
  Retain the existing `agent_cmd`-override guard (`Keyword.has_key?(opts, :agent_cmd) and
  agent_cmd != "docker"`): an explicit override still dispatches as directed; only its absence
  routes to the sandbox.
- **Rationale**: FR-005 requires removal, not avoidance, so a future edit cannot silently
  re-enable it. FR-006 requires the test/harness override to keep working — it does, because
  the override guard is untouched. Existing generated-agent tests
  (`run_worker_transcript_test.exs`) already pass explicit `agent_cmd: "echo"` overrides and
  therefore stay green; `world_b_generated_test.exs` operates below dispatch and is unaffected.
- **Migration risk**: LOW. Audited callers of `run_once(agent: …)` without an override — none
  in production expect host-python (production dispatch is exactly what this feature jails);
  the only overrides are in tests and are preserved.

## D6 — Test gating for the containment probe (Constitution IV)

- **Decision**: `test/agent_os/generated_containment_test.exs`, `use ExUnit.Case, async: false`,
  every case `@tag :docker`. Modelled on `isolation_test.exs`. Excluded from the default run
  by `test/test_helper.exs` (`exclude: [:docker]`); executes where Docker is present.
- **Rationale**: Docker is a local runtime, not a remote API, so it does not violate
  Constitution IV; gating keeps the default suite hermetic. The inference broker stays the
  deterministic stub the world-B suite already uses.
