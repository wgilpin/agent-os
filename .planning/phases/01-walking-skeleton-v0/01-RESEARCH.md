# Phase 1: Walking Skeleton (v0) - Research

**Researched:** 2026-06-27
**Domain:** BEAM/OTP (Elixir) control plane orchestrating a one-shot Python agent across a process boundary
**Confidence:** HIGH (toolchain + boundary mechanics verified; some v0 design choices are judgment calls flagged as ASSUMED)

## Summary

This phase builds the thinnest real end-to-end slice of an "agent OS": an Elixir/OTP supervision tree that, on a daily 07:00 timer, fires a single supervisor → a single Erlang `Port` → a hand-written Python discovery agent, which reasons over hand-fed input and emits enumerated proposed actions as structured data. The substrate (not the agent) then performs the privileged action deterministically after a minimal output check, mounts state mount behind a single-writer GenServer, writes a legible run-log + standing inventory, and restarts-once-and-alerts on child failure. It is a STRUCTURAL milestone — the test is "does the one-supervisor / one-store / one-port skeleton feel right?", not "is the agent good." [CITED: docs/agent-os-design.md §c]

The single load-bearing technical question is **cross-boundary failure semantics**: how a Python crash/OOM/kill surfaces to the BEAM supervisor as a clean process exit so let-it-crash works, without leaking orphaned OS processes. The good news for v0: the daily one-shot invocation model (run-to-completion, not a long-lived server) makes this dramatically simpler than the long-lived case. A plain Erlang `Port` with `:exit_status` + a tiny stdin-guard wrapper script gives clean exit-code surfacing and no orphans, with zero added dependencies. [VERIFIED: hexdocs Port docs; multiple ecosystem sources]

**Primary recommendation:** Single non-umbrella Mix app. Erlang `Port` (`:spawn_executable` + `:exit_status` + `:binary` + line/length framing) wrapped in a `port_wrapper.sh` stdin-guard, invoked once per trigger and awaited to completion inside a per-run `Task` under a `Task.Supervisor`. Single-writer `GenServer` for roster/trust (term-file or ETS persistence). `Process.send_after` self-rescheduling GenServer for the 07:00 timer (NOT Quantum at v0). JSON over stdout (Jason) as the agent→substrate transport. `yaml_elixir` to parse YAML-frontmatter manifest fields. Restart-once-and-alert via a `:transient` child with `max_restarts: 1` under a dedicated supervisor whose own `:shutdown` is trapped/monitored to fire the alert. No database at v0.

## User Constraints

> No CONTEXT.md exists for this phase yet (status: "Ready to plan", 0 plans). The constraints
> below are extracted from the locked-by-exploration design decisions in
> `.planning/intel/decisions.md` and `constraints.md`. These are PROPOSED, not locked ADRs —
> but they bound this phase's scope and the planner should treat them as decisions unless the
> user overrides them in discuss-phase.

### Decisions (from design doc — proposed/settled-by-exploration)
- **Substrate owns all state + scheduling.** The substrate is the only thing that persists; agents are invocation-scoped pure functions that run once and die. [DEC-substrate-owns-all-state, DEC-invocation-scoped-agents]
- **Single writer per mutable store.** Roster/trust KG is owned by ONE GenServer; mutation only via messages to it; no locks because no sharing. [DEC-single-writer-per-store]
- **Remove the LLM from the credential boundary.** The privileged action runs deterministically ON the agent's behalf after a check — the agent never holds the credential. Even at v0 (where there is no real credential yet) the *shape* must be: agent proposes, substrate acts. [DEC-remove-llm-from-credential-boundary]
- **No ambient authority.** The agent's manifest grants are its entire power. At v0 the grant is hand-kept and not yet enforced, but the act-on-behalf step must read from the declared grant, not from agent free-choice. [DEC-no-ambient-authority]
- **Declarative manifest is the single source of truth**, hand-written markdown, human-kept-in-sync. Seven core fields: purpose, trigger(s), connectors(+scope), mounts, outputs, spend, owner/supervision. [DEC-declarative-manifest..., CON-manifest-seven-fields]
- **Legibility is non-negotiable, the one principle with no flag.** Standing inventory of what exists + legible run-log of what it did. Never "ask the agent." [DEC-legibility-non-negotiable]
- **BEAM/OTP (Elixir) is the control plane; Python/PydanticAI does the LLM work across a port/HTTP boundary.** Elixir now, Gleam deferred-not-rejected. [DEC-runtime-beam-otp-elixir-now]
- **Run-to-completion with kill-based preemption.** v0 needs run-to-completion + restart-once-and-alert; the spend-cap *kill* is a number-only stub at v0 (no real on_breach kill until v2/Phase 3). [DEC-run-to-completion-with-kill-preemption]

### Claude's Discretion (v0-appropriate engineering choices)
- Exact boundary mechanism (Port vs erlexec vs MuonTrap vs HTTP/stdio JSON-RPC) — researched below, recommendation given.
- Scheduler mechanism (Process.send_after vs Quantum) — recommendation given.
- Persistence for roster/trust + inventory (term file vs ETS+DETS vs git-backed markdown) — recommendation given.
- Mix project layout (single app vs umbrella) — recommendation given.
- Manifest parsing approach (YAML frontmatter vs bespoke parser).

### Deferred Ideas (OUT OF SCOPE for Phase 1 — do not build)
- Container/isolation of the agent (v1 / Phase 2). v0 runs the Python agent as a bare local subprocess.
- Real deterministic enforcement gate, credential proxy, spend metering, on_breach kill (v2 / Phase 3). v0's check is a "minimal output check, not enforcement."
- Sanitizing untrusted web input — v0 input is hand-fed and unsanitized by design. [REQ-reason-over-input R1]
- Provisioning from an arbitrary manifest — v0 provisioning is HARD-WIRED config; the human keeps the markdown manifest in sync by hand. [REQ-instantiate-from-declaration R1]
- Agent generation / synthesis pipeline / security-review / conformance auditor (v3 / Phase 4).
- Event-triggers, message-triggers, approval-as-event — v0 has ONE time-trigger only.
- `REQ-surface-child-crash` as a HARDENED guarantee is Phase 2's own deliverable (containerized OOM). v0 should get the bare-process version working and design the seam so the containerized version drops in later.

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| REQ-write-manifest | Hand-write markdown manifest, human-kept-in-sync | Markdown + YAML frontmatter; `yaml_elixir` 2.12.2 parses the grant fields. Plan stub 01-02. |
| REQ-state-purpose | Purpose as one-line contract | Single `purpose:` string field in manifest frontmatter; rendered as top inventory line. |
| REQ-grant-connectors-mounts | Connectors + mounts listed by hand | List fields in manifest; at v0 read for display + to drive act-on-behalf, not enforced. |
| REQ-set-spend-cap | Spend cap as a number (no on_breach yet) | Plain integer field; no kill logic at v0 (deferred to Phase 3). |
| REQ-instantiate-from-declaration | Hard-wired config, NOT provisioned from manifest | v0 wires the one agent in code/config; manifest is documentation the human syncs. |
| REQ-mount-state | Roster/trust mounted to single-writer GenServer | Single-writer GenServer pattern (below). Plan stub 01-01. |
| REQ-trigger-time | One timer — daily 07:00 | `Process.send_after` self-rescheduling GenServer (below). Plan stub 01-02. |
| REQ-hand-input | One port → human-written Python agent | Erlang Port + wrapper (below). Plan stub 01-03. |
| REQ-reason-over-input | LLM reasons over input, unsanitized at v0 | Python/PydanticAI 2.0.0 agent; input passed as stdin/arg. |
| REQ-propose-enumerated-actions | Proposes enumerated actions | Agent emits a JSON list of typed actions on stdout (Jason decodes). |
| REQ-validate-action-vs-grants | Minimal output check, NOT enforcement | Deterministic Elixir function: shape-check + each action's type ∈ declared outputs/connectors. Plan stub 01-04. |
| REQ-act-on-behalf | Privileged action on agent's behalf, deterministic | Substrate executes the validated action (e.g. append to digest log); agent never acts. Plan stub 01-04. |
| REQ-list-inventory | Standing inventory of what exists | Render manifest fields + last-run status from GenServer/term-file. Plan stub 01-05. |
| REQ-read-run-trace | A legible run-log | Structured `Logger` + an append-only human-readable run-log file (git-backed markdown candidate). Plan stub 01-05. |
| REQ-restart-policy | Restart-once-and-alert | `:transient` child, `max_restarts: 1`, alert on supervisor shutdown (below). Plan stub 01-05. |

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Scheduling (07:00 trigger) | BEAM substrate | — | Substrate owns all scheduling (DEC). Triggers are data. |
| State mount ownership | BEAM substrate (single-writer GenServer) | term-file/ETS | Substrate is the only persistent thing; contended mutable state needs one owner. |
| Supervision / restart / alert | BEAM substrate (OTP supervisor) | — | This is exactly what OTP supervision trees are for. |
| LLM reasoning over input | Python agent (across port) | — | Heavy ML work; "mad to do in Erlang" (design doc). |
| Proposing enumerated actions | Python agent | — | Agent's only job: reason + propose. It never acts. |
| Output check (minimal) | BEAM substrate (deterministic) | — | The check must be deterministic and outside the agent (user/kernel ring split). |
| Privileged act-on-behalf | BEAM substrate (deterministic) | — | "No component both runs an LLM and holds a credential." Substrate acts. |
| Run-log + inventory rendering | BEAM substrate | git-backed markdown | Legibility is the substrate's job; never ask the agent. |
| Manifest authoring + sync | Human (out of band) | — | v0: hand-kept-in-sync, not machine-provisioned. |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Elixir | 1.20.2 (installed) | Control-plane language | Locked by DEC-runtime-beam-otp-elixir-now. [VERIFIED: `elixir --version`] |
| Erlang/OTP | 29 (installed) | VM, supervision, ports | Supervisors, GenServer, Port are stdlib — no dep needed. [VERIFIED: `erl`] |
| Erlang `Port` | stdlib (OTP) | BEAM↔Python boundary | Built-in, zero-dep, exit-code surfacing via `:exit_status`. See boundary analysis. [VERIFIED: hexdocs Port] |
| `jason` | 1.4.5 | JSON encode/decode for agent I/O | De-facto Elixir JSON lib; agent emits JSON actions on stdout. [VERIFIED: hex.pm 2026-05-05] |
| `yaml_elixir` | 2.12.2 | Parse YAML frontmatter in the markdown manifest | Idiomatic wrapper over native Erlang `yamerl`. [VERIFIED: hex.pm 2026-05-30] |
| Python | 3.14.6 (installed) / project pins `>=3.11` | Agent runtime | pyproject.toml present. [VERIFIED: `python3 --version`, pyproject.toml] |
| `pydantic-ai` | 2.0.0 | Python LLM agent framework | Named in design doc; emits structured (Pydantic) outputs ⇒ clean JSON actions. [VERIFIED: pypi] |
| `pydantic` | 2.13.4 | Structured action schema on the Python side | Pairs with pydantic-ai; enforces enumerated-action shape before it crosses the boundary. [VERIFIED: pypi] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `:logger` | stdlib | Structured run-log | Always. Pair with a human-readable run-log file. |
| ETS / DETS / `:erlang.term_to_binary` | stdlib | Roster/trust + inventory persistence | If you want zero deps. Term-file (`File.write!` + `:erlang.term_to_binary`) is the minimal v0 choice. |
| `muontrap` | 1.8.0 | Contain/kill external processes + children | NOT needed at v0 (one-shot bare process). Becomes relevant in Phase 2 (containerized, long-lived-ish). [VERIFIED: hex.pm 2026-06-01] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Erlang `Port` | `:erlexec` 2.3.4 | erlexec always kills spawned processes + offers SIGTERM→SIGKILL escalation and process-group kill — better for long-lived/killable children (Phase 3 spend-cap kill). Overkill for a one-shot v0 process; adds a NIF/port-program dep. Revisit when on_breach kill is built. [VERIFIED: hex.pm 2026-06-12] |
| Erlang `Port` | `MuonTrap` 1.8.0 | Great at "kill the OS process + all children if the Elixir side dies," cgroups on Linux. BUT "not great for interactive programs that communicate via the port" — and v0 *does* communicate (sends input, reads JSON). Better fit at Phase 2 when the agent is containerized. [VERIFIED: muontrap README] |
| Erlang `Port` | `Porcelain` | Largely unmaintained; historically needed a Go helper (`goon`) for full features and is widely discouraged for new code. Avoid. [CITED: elixirforum discussions] |
| stdout JSON | HTTP / stdio JSON-RPC server | A request/response transport implies a *long-lived* Python server — contradicts invocation-scoped run-once-and-die. JSON-over-stdout of a one-shot process is the natural fit for v0. Reconsider HTTP only if/when the agent must stream or be containerized as a service. |
| `Process.send_after` | `Quantum` 3.5.3 | Quantum is robust cron-for-Elixir w/ timezone handling, but it is a dep + GenStage machinery for ONE daily job. v0 wants minimal. `Process.send_after` self-reschedule is ~15 lines. Use Quantum if/when there are several cron triggers. [VERIFIED: hex.pm; quantum last release 2024-02] |
| Term-file persistence | Postgres / SQLite / Ecto | A DB is over-engineering for one roster + a run-log at v0. (Global rule: IF a live DB is used, it needs a dedicated test DB + backups — but v0 should avoid the DB entirely.) |
| Single app | Umbrella project | Umbrella adds ceremony for no v0 benefit; one supervision tree, one app. Recommend single app. |

**Installation (Elixir side, mix.exs deps):**
```elixir
{:jason, "~> 1.4"},
{:yaml_elixir, "~> 2.12"}
# muontrap / erlexec intentionally NOT added at v0
```

**Installation (Python side):**
```bash
# project uses uv (pyproject.toml). Add to dependencies:
# pydantic-ai>=2.0.0  (pulls pydantic>=2.13)
uv add pydantic-ai
```

## Architecture Patterns

### System Architecture Diagram

```
                    ┌─────────────────────────────────────────────────────┐
                    │              BEAM / OTP (control plane)               │
                    │                                                       │
  daily 07:00 ─────▶│  [Scheduler GenServer]                                │
  (Process.send_after│   send_after(self, :fire, ms_until_0700)            │
   self-reschedule)  │        │ :fire                                       │
                    │        ▼                                              │
                    │  [Run Supervisor]  (:transient child, max_restarts:1) │
                    │        │ start child                                  │
                    │        ▼                                              │
                    │  [Run Worker / Task]                                  │
                    │    1. read hard-wired config + manifest fields        │
                    │    2. read mounted state  ◀──┐                        │
                    │    3. open Port ───────────┐ │   (read-only snapshot) │
                    │    6. minimal output check │ │                        │
                    │    7. act-on-behalf ───────┼─┼──▶ [Roster/Trust       │
                    │    8. append run-log       │ │     GenServer]         │
                    │        │ on crash          │ │   (single writer;      │
                    │        ▼                   │ │    serialize by mailbox)│
                    │  restart once → on 2nd     │ │                        │
                    │  failure supervisor :shutdown│ │                       │
                    │        │                   │ │                        │
                    │        ▼                   │ │                        │
                    │  [Alerter] ── log/notify   │ │                        │
                    └────────────────────────────┼─┼────────────────────────┘
                                                 │ │ stdin: input JSON
                                          ┌──────▼─┴──────┐
                                          │ port_wrapper.sh│  (stdin-guard:
                                          │  exec python   │   kills child if
                                          └──────┬─────────┘   BEAM/stdin dies)
                                                 │
                                          ┌──────▼─────────┐
                                          │ Python agent   │  reasons over input,
                                          │ (pydantic-ai)  │  emits JSON list of
                                          │  run once, die │  enumerated actions
                                          └──────┬─────────┘  on stdout, exit(0)
                                                 │ stdout: {"actions":[...]}
                                                 │ exit_status: 0 | nonzero
                                          back to Run Worker (step 4: collect,
                                          step 5: await {port,{:exit_status,s}})
```

Trace: timer fires → supervisor starts a transient worker → worker opens a Port to the wrapper → wrapper execs Python → Python reads input, reasons, prints JSON actions, exits → worker receives `{:data, ...}` then `{:exit_status, 0}` → worker runs the minimal check → substrate performs each valid action (writes to the roster GenServer / digest log) → worker appends a run-log line. If Python exits nonzero or the worker crashes, the supervisor restarts it once; a second failure trips `max_restarts` and the run-supervisor shuts down → Alerter fires.

### Recommended Project Structure
```
agent_os/                      # single Mix app (NOT umbrella)
├── mix.exs
├── config/
│   └── config.exs             # hard-wired agent config (v0: not provisioned from manifest)
├── manifests/
│   └── discovery.md           # hand-written markdown manifest w/ YAML frontmatter (human-kept)
├── priv/
│   └── port_wrapper.sh        # stdin-guard wrapper for clean child teardown
├── agents/
│   └── discovery/             # Python agent (pydantic-ai), run-once-and-die
│       ├── main.py            # reads stdin, prints JSON actions, exits
│       └── pyproject deps via root pyproject.toml
├── lib/
│   └── agent_os/
│       ├── application.ex      # OTP app + top supervision tree
│       ├── scheduler.ex        # GenServer: Process.send_after daily-0700
│       ├── run_supervisor.ex   # supervises the per-run worker (restart-once-and-alert)
│       ├── run_worker.ex       # opens Port, collects output, runs check, acts-on-behalf
│       ├── port_runner.ex      # thin Port wrapper: open/await/exit_status
│       ├── state_store.ex     # single-writer GenServer (mounted state)
│       ├── manifest.ex         # parse YAML frontmatter from manifests/*.md
│       ├── output_check.ex     # minimal deterministic action validation
│       ├── effector.ex         # deterministic act-on-behalf
│       ├── run_log.ex          # legible append-only run-log
│       ├── inventory.ex        # standing inventory render
│       └── alerter.ex          # fires when supervisor gives up
├── data/                       # term-file persistence (gitignored if mutable)
│   ├── roster.term
│   └── run_log.md              # legible, git-trackable
└── test/
```

### Pattern 1: One-shot Port with clean exit-status surfacing
**What:** Open a Port to a wrapper script, feed input on stdin, collect stdout, await `:exit_status`. The exit code is the clean signal that crosses the boundary.
**When to use:** Every agent invocation at v0 (run-once-and-die, not a server).
**Example:**
```elixir
# Source: hexdocs Port docs + tonyc.github.io managing-external-commands
# priv/port_wrapper.sh is the officially-recommended stdin-guard wrapper.
def run(input_json, python_args) do
  wrapper = Path.join(:code.priv_dir(:agent_os), "port_wrapper.sh")
  port =
    Port.open(
      {:spawn_executable, wrapper},
      [
        :binary,
        :exit_status,                 # ⇒ {port, {:exit_status, status}} on child exit
        {:args, python_args},         # ["python3", "agents/discovery/main.py"]
        {:line, 1_000_000}            # or :stream + your own framing
      ]
    )
  Port.command(port, input_json)       # feed input on stdin
  collect(port, [])
end

defp collect(port, acc) do
  receive do
    {^port, {:data, chunk}} -> collect(port, [acc | chunk])
    {^port, {:exit_status, 0}}    -> {:ok, IO.iodata_to_binary(acc)}
    {^port, {:exit_status, code}} -> {:error, {:exit_status, code}}
  after
    timeout_ms() ->
      Port.close(port)                 # closing stdin ⇒ wrapper kills child ⇒ no orphan
      {:error, :timeout}
  end
end
```
**Exact message tuples** [VERIFIED: hexdocs Port]: data arrives as `{port, {:data, data}}`; child exit as `{port, {:exit_status, status}}` (only when `:exit_status` is set); a port crash as `{:EXIT, port, reason}` (only when the owner traps exits).

### Pattern 2: The stdin-guard wrapper script (orphan prevention)
**What:** A tiny bash wrapper that runs Python in the background and kills it if stdin closes (which happens when the BEAM port closes or the VM dies). This is the officially-documented Elixir solution.
**Why:** "If the VM crashes, a long-running program started by the port will have its stdin and stdout channels closed but it won't be automatically terminated." The wrapper closes that gap with zero deps. [CITED: hexdocs Port]
**Example:**
```bash
#!/usr/bin/env bash
# priv/port_wrapper.sh — based on the Elixir Port docs' recommended wrapper
"$@" &                  # exec the real command (python3 main.py ...) in background
pid=$!
while read -r line ; do : ; done   # block until stdin closes
kill -KILL "$pid" 2>/dev/null       # stdin closed ⇒ tear the child down
```
(Make executable; ship via `priv/`. For v0's one-shot model this is sufficient — Phase 2 may replace it with MuonTrap/cgroups or container kill.)

### Pattern 3: Single-writer GenServer for roster/trust
**What:** One process owns the mutable state mount. All reads and mutations go through its mailbox; serialization is by construction, no locks.
**When to use:** The mounted state (REQ-mount-state). The design doc is explicit: a KG doesn't git-merge, the trust engine has numerically-sensitive contended state, lost-update is real corruption. [CITED: CON-state-store-concurrency-profiles]
**Example:**
```elixir
defmodule AgentOS.StateStore do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # reads: snapshot for the agent run (agent gets a copy, never the live state)
  def snapshot(), do: GenServer.call(__MODULE__, :snapshot)
  # writes: the ONLY mutation path — substrate acts on behalf
  def apply_action(mount, action), do: GenServer.call(__MODULE__, {:apply, action})

  @impl true
  def init(_), do: {:ok, load_from_term_file()}
  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}
  def handle_call({:apply, action}, _from, state) do
    new_state = mutate(state, action)
    persist_term_file(new_state)        # term_to_binary; atomic write+rename
    {:reply, :ok, new_state}
  end
end
```
**Key:** the agent receives a *snapshot* (copy) as input; it cannot mutate state directly. The substrate's effector calls `apply_action/1`. This bakes in the user/kernel ring split at v0.

### Pattern 4: Restart-once-and-alert
**What:** A child that is restarted at most once; on the second failure the supervisor hits `max_restarts` and itself exits `:shutdown`; a monitor/parent catches that and fires the alert.
**When to use:** REQ-restart-policy. The OTP defaults are 3 restarts / 5 seconds; for "restart ONCE" set `max_restarts: 1`. [VERIFIED: hexdocs Supervisor]
**Example:**
```elixir
defmodule AgentOS.RunSupervisor do
  use Supervisor
  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_) do
    children = [
      # :transient ⇒ restarted only on ABNORMAL exit (crash), not on :normal completion.
      # A successful one-shot run exits :normal and is NOT restarted (correct for run-once).
      Supervisor.child_spec({AgentOS.RunWorker, []}, restart: :transient)
    ]
    # max_restarts: 1 within max_seconds ⇒ one retry; a 2nd crash trips intensity.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 1, max_seconds: 60)
  end
end
```
**Alerting when it gives up:** when intensity is exceeded the supervisor terminates with reason `:shutdown` [VERIFIED: hexdocs Supervisor]. Catch this one level up — the parent that starts `RunSupervisor` either (a) starts it `:temporary` and `Process.monitor`s it, firing `Alerter` on the `:DOWN`, or (b) wraps the run in a `Task.Supervisor` + `Task.async_nolink` and pattern-matches the failure result. For v0, option (b) — a `Task.Supervisor` with an explicit "try once, on failure retry once, on second failure alert" loop in the Scheduler/RunWorker — is often *simpler and more legible* than nesting supervisors, and keeps the "restart once" count explicit and inspectable. Flag both for the planner; recommend (b) for v0 legibility. [ASSUMED — both are valid OTP idioms; pick by legibility]

### Pattern 5: Daily 07:00 self-rescheduling timer
**What:** A GenServer computes ms until next 07:00, `Process.send_after(self(), :fire, ms)`, handles `:fire` by launching the run AND scheduling the next day.
**Example:**
```elixir
defmodule AgentOS.Scheduler do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  @impl true
  def init(_), do: {:ok, schedule_next()}
  @impl true
  def handle_info(:fire, state) do
    AgentOS.RunSupervisor.run_now()      # or start the run task
    {:noreply, schedule_next()}
  end
  defp schedule_next() do
    ms = ms_until_next_0700()            # use a fixed tz; DateTime + Timex-free arithmetic
    Process.send_after(self(), :fire, ms)
    %{next: ms}
  end
end
```
**Timezone caveat:** "07:00" needs an explicit timezone. OTP 29 / Elixir 1.20 `DateTime` handles UTC natively; for a local-time 07:00 you need a tz database (`tz` or `tzdata` hex lib) OR pin the trigger to UTC for v0. Recommend: **pin to a single configured timezone, compute next-occurrence explicitly, document it.** [ASSUMED — exact tz handling is a v0 simplification choice]

### Anti-Patterns to Avoid
- **Agent holds the credential / performs the effect.** Violates DEC-remove-llm-from-credential-boundary. The Python agent must ONLY emit proposed actions; the Elixir effector performs them.
- **Sharing the roster across processes / using ETS public-write from many writers.** Violates single-writer. ETS is fine as the GenServer's *private* backing store, but writes must funnel through the one owner.
- **Long-lived Python server (HTTP/JSON-RPC) at v0.** Contradicts invocation-scoped run-once-and-die; reintroduces lifecycle state the architecture removes.
- **Spawning Python directly via `:spawn_executable` of `python3` with no wrapper.** Risks orphaned OS processes on BEAM crash. Use the stdin-guard wrapper.
- **Reaching for Quantum/Oban/a DB for one daily job + one roster.** Over-engineering for a structural skeleton.
- **Letting `:exit_status` be the *only* health signal.** A Python process can hang without exiting; pair `:exit_status` with a `receive ... after timeout` and `Port.close`.
- **Umbrella project.** Adds layout ceremony with no v0 payoff.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Supervision / restart-intensity / let-it-crash | A custom retry/monitor framework | OTP `Supervisor` + `:transient` + `max_restarts` | This is BEAM's core competency; the design doc chose BEAM *because* "the supervisor and watchdog questions vanish into the runtime." |
| Serializing contended state | Locks / mutexes / a DB transaction | A single-writer `GenServer` (mailbox = serialization) | No sharing ⇒ no locks; the 1970s answer (CSP/actors) per the design doc. |
| External-process orphan cleanup | A bespoke PID-tracking reaper | stdin-guard wrapper now; `muontrap`/`erlexec` later | Officially-documented pattern; reapers are subtly wrong (signal races, process groups). |
| JSON parsing | Hand-rolled parser | `jason` 1.4.5 | Battle-tested, fast, standard. |
| YAML frontmatter parsing | Regex-only field extraction | `yaml_elixir` 2.12.2 (split frontmatter, parse YAML) | Hand regex breaks on quoting/lists/nesting; the manifest has list + sub-block fields. |
| Structured action output from the agent | Free-text the substrate parses heuristically | `pydantic`/`pydantic-ai` typed output → JSON | Enumerated actions are a *schema*; let Pydantic enforce shape before it crosses the boundary. |

**Key insight:** v0's entire value is proving the OTP skeleton feels right. Every place you'd hand-roll a supervisor/lock/reaper is a place you'd be reinventing what BEAM already gives you — which would mean you chose the wrong runtime. Lean on stdlib hard; add deps only for JSON, YAML, and the Python agent framework.

## Common Pitfalls

### Pitfall 1: Orphaned Python OS process on BEAM crash
**What goes wrong:** BEAM dies or the port closes, but the Python process keeps running, consuming resources / spend, invisible to the supervisor.
**Why it happens:** A spawned OS process is only loosely coupled to the port; closing stdin/stdout does not kill an arbitrary child. [CITED: hexdocs Port]
**How to avoid:** stdin-guard wrapper script (Pattern 2). Verify by killing the BEAM node mid-run and checking `ps` shows no surviving Python.
**Warning signs:** `ps aux | grep python` shows agents after the scheduler is stopped.

### Pitfall 2: Hung Python never surfaces as an exit
**What goes wrong:** The agent deadlocks (e.g. waits on an LLM API that never returns); no `:exit_status` ever arrives; the run worker blocks forever.
**Why it happens:** `:exit_status` only fires on actual process exit; a hang is not an exit.
**How to avoid:** `receive ... after timeout_ms -> Port.close(port)`; the wrapper then kills the child. Treat timeout as an abnormal exit for restart-once-and-alert.
**Warning signs:** Run worker mailbox stuck; no run-log line written.

### Pitfall 3: OOM surfacing is OS-dependent (and is Phase 2's real test)
**What goes wrong:** A Python OOM under the Linux OOM-killer arrives as SIGKILL → nonzero/ças exit; in a container it may surface differently; on macOS dev it behaves differently again.
**Why it happens:** OOM is an OS/cgroup behaviour, not a BEAM one. v0 runs the agent as a bare local process; REQ-surface-child-crash's *hardened* form is explicitly Phase 2 (containerized).
**How to avoid (v0):** Treat ANY nonzero exit_status (incl. signal-induced) as an abnormal child exit that drives restart-once-and-alert. Design the `port_runner`/wrapper seam so a container's exit code drops in unchanged in Phase 2. Document that real OOM-in-container surfacing is verified in Phase 2.
**Warning signs:** Assuming a clean exit code 0 on memory pressure.

### Pitfall 4: Manifest drift (the human forgets to sync)
**What goes wrong:** v0 provisioning is hard-wired in code/config but the markdown manifest is the "single source of truth" — they silently diverge, defeating legibility.
**Why it happens:** v0 explicitly does NOT provision from the manifest (REQ-instantiate-from-declaration R1), relying on the human to keep them in agreement.
**How to avoid:** Add a tiny startup consistency check that reads the manifest fields and asserts they match the hard-wired config; log a loud warning on mismatch. Cheap, and it makes the "human-kept-in-sync" promise observable. [ASSUMED — a v0-appropriate safeguard, not a stated requirement]
**Warning signs:** Inventory shows manifest values that don't match runtime behaviour.

### Pitfall 5: Timezone ambiguity in "07:00"
**What goes wrong:** Trigger fires at the wrong hour, or DST shifts it.
**Why it happens:** Naive local-time arithmetic without a tz database.
**How to avoid:** Pin to a single configured tz (or UTC) for v0; compute next-occurrence explicitly; if local wall-clock 07:00 matters, add `tz`/`tzdata` and document.
**Warning signs:** Run fires an hour off after a DST boundary.

### Pitfall 6: `:transient` vs `:temporary` confusion breaks restart-once
**What goes wrong:** A successful one-shot run exits `:normal`; with `:permanent` the supervisor would restart it immediately (infinite loop); with `:temporary` a crash is never restarted (no retry).
**Why it happens:** Misreading OTP restart semantics. [VERIFIED: hexdocs Supervisor]
**How to avoid:** Use `:transient` — restart only on abnormal exit — so success isn't re-run and a crash retries once (with `max_restarts: 1`). Test all three exit paths (normal / crash-once / crash-twice).

## Code Examples

### Minimal output check + deterministic act-on-behalf
```elixir
# Source: pattern derived from CON-enforcement-spine (design doc §b)
# v0 = "minimal output check, not enforcement" + deterministic effect.
defmodule AgentOS.OutputCheck do
  @doc "Shape-check + each action's type must be in the declared outputs/connectors."
  def validate(actions, manifest) when is_list(actions) do
    allowed = MapSet.new(manifest.outputs ++ manifest.connectors)
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, acc} ->
      cond do
        not is_map(action) -> {:halt, {:error, {:bad_shape, action}}}
        not Map.has_key?(action, "type") -> {:halt, {:error, {:no_type, action}}}
        not MapSet.member?(allowed, action["type"]) ->
          {:halt, {:error, {:ungranted, action["type"]}}}   # minimal check, logged not enforced
        true -> {:cont, {:ok, [action | acc]}}
      end
    end)
  end
  def validate(_, _), do: {:error, :not_a_list}
end

defmodule AgentOS.Effector do
  @doc "Substrate performs the privileged action ON the agent's behalf, deterministically."
  def act(%{"type" => "record_signal"} = a),
    do: AgentOS.StateStore.apply_action({:record, a["payload"]})
  def act(%{"type" => "append_digest"} = a),
    do: AgentOS.RunLog.append_digest(a["payload"])
  # the agent never holds a credential; the effector is the only thing that mutates the world
end
```

### Manifest (hand-written markdown + YAML frontmatter)
```markdown
<!-- manifests/discovery.md -->
---
purpose: "Surface high-signal AI/ML content from the people-roster, read-and-digest only."
triggers:
  - type: time
    at: "07:00"
connectors:
  - record_signal       # v0: coarse; v2 gains scope + constraints sub-block
mounts:
  - roster_trust
outputs:
  - append_digest
spend:
  cap: 5                 # a number only at v0; {cap, window, on_breach} arrives in Phase 3
owner: human
supervision: restart-once-and-alert
---
# Discovery agent
One-line human description kept in sync with config/config.exs by hand.
```
```elixir
# Source: yaml_elixir README pattern
defmodule AgentOS.Manifest do
  def load(path) do
    [_, frontmatter, _body] = File.read!(path) |> String.split(~r/\n-{3,}\n/, parts: 3)
    {:ok, map} = YamlElixir.read_from_string(frontmatter)
    map
  end
end
```

### Python agent: run-once, emit JSON actions, exit
```python
# agents/discovery/main.py — invocation-scoped: read stdin, reason, print JSON, exit.
# Source: pydantic-ai structured-output pattern (pydantic-ai 2.0.0)
import sys, json
from pydantic import BaseModel

class Action(BaseModel):
    type: str
    payload: dict

def main() -> int:
    raw = sys.stdin.read()
    input_data = json.loads(raw) if raw.strip() else {}
    # ... pydantic-ai Agent reasons over input_data, produces typed actions ...
    actions = [Action(type="append_digest", payload={"text": "..."})]
    json.dump({"actions": [a.model_dump() for a in actions]}, sys.stdout)
    sys.stdout.flush()
    return 0          # clean exit ⇒ {port, {:exit_status, 0}} on the BEAM side

if __name__ == "__main__":
    sys.exit(main())
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `Porcelain` (+ goon) for external procs | `Port` + wrapper, or `muontrap`/`erlexec` | Porcelain effectively unmaintained for years | Don't pick Porcelain for new code. |
| `Supervisor.Spec` / `:simple_one_for_one` | Child specs as maps / `DynamicSupervisor` / `Task.Supervisor` | Elixir 1.5+ | Use modern child-spec map form; `Supervisor.Spec` is legacy. |
| pydantic-ai v0.x rapid churn | pydantic-ai **2.0.0** (pydantic 2.13) | 2026 | Pin `>=2.0`; v0.x→2.0 had API changes. [VERIFIED: pypi] |

**Deprecated/outdated:**
- `Supervisor.Spec` module — superseded by child-spec maps (still works, don't use in new code).
- Porcelain — avoid.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Restart-once-and-alert via `Task.Supervisor` + explicit retry loop is more legible than nested supervisors at v0 | Pattern 4 | Low — both are valid OTP; planner can choose. Mis-choice costs some clarity, not correctness. |
| A2 | Pin the 07:00 trigger to a single configured tz / UTC for v0 (no full tz DB) | Pattern 5, Pitfall 5 | Medium — if the user needs local wall-clock 07:00 across DST, must add `tz`/`tzdata`. Confirm desired tz. |
| A3 | A startup manifest↔config consistency check is a good v0 safeguard | Pitfall 4 | Low — it's an additive safeguard, not a requirement. Could be cut for minimalism. |
| A4 | Term-file (`term_to_binary` + atomic write) is sufficient persistence for roster/trust + run-log at v0 (no DB) | Standard Stack | Medium — if the roster is already large/relational, ETS+DETS or a small store may fit better. Confirm roster size/shape. |
| A5 | JSON-over-stdout of a one-shot process (not HTTP/JSON-RPC) is the right v0 transport | Alternatives | Medium — if the agent must stream progress or the team prefers a service boundary early, reconsider. Aligns with invocation-scoped principle. |
| A6 | The "minimal output check" validates action-type ∈ declared outputs/connectors and shape only (logs, does not block) at v0 | Code Examples | Medium — "minimal, not enforcement" is per requirement, but the exact check semantics (log vs soft-reject) should be confirmed in discuss-phase. |
| A7 | Run-log as git-backed markdown is the right legible-log substrate | Architecture | Low — design doc explicitly endorses git-backed markdown for append-only digest logs. |

## Open Questions

1. **Restart-once topology: nested supervisor vs Task.Supervisor + retry loop.**
   - What we know: both achieve restart-once-and-alert; `max_restarts: 1` + `:transient` is the supervisor route; an explicit try/retry/alert loop is the Task route.
   - What's unclear: which the user finds more *legible* (the v0 acceptance bar is "does the skeleton feel right").
   - Recommendation: prototype the Task.Supervisor route for v0 legibility; note the supervisor route as the "more OTP-canonical" alternative.

2. **Timezone for "07:00."**
   - What we know: needs an explicit tz; UTC is dependency-free.
   - What's unclear: does the user want local wall-clock 07:00 (DST-aware)?
   - Recommendation: confirm tz in discuss-phase; default to a single configured tz, add `tz` lib only if DST-correct local time is required.

3. **Exact "minimal output check" semantics (log-only vs soft-reject).**
   - What we know: v0 is explicitly "minimal check, NOT enforcement" (REQ-validate-action-vs-grants R1).
   - What's unclear: should an out-of-grant action be dropped, or executed-with-a-warning, at v0?
   - Recommendation: drop-and-log (don't execute ungranted actions) — it pre-shapes the act-on-behalf path toward the v2 gate without claiming to be the gate. Confirm with user.

4. **State mount shape and size.**
   - What we know: it's a contended KG behind one writer; term-file persistence is the minimal choice.
   - What's unclear: initial schema/size — affects whether term-file or ETS+DETS is right.
   - Recommendation: define the minimal roster schema during planning; start with term-file.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Elixir | Control plane | ✓ | 1.20.2 | — |
| Erlang/OTP | VM, ports, supervision | ✓ | 29 (erts 17.0.2) | — |
| Mix | Build/deps | ✓ | 1.20.2 | — |
| Python | Agent runtime | ✓ | 3.14.6 (project pins >=3.11) | — |
| bash | port_wrapper.sh | ✓ (macOS/zsh env has bash) | system | sh-compatible rewrite |
| LLM API (Vertex/Anthropic) for pydantic-ai | Real agent reasoning | ✗ (not verified in session) | — | Stub the agent to emit a fixed JSON action list — sufficient for the STRUCTURAL skeleton test; real LLM call is not required to prove the spine. |
| `jason`, `yaml_elixir`, `pydantic-ai` | Deps | ✗ (not yet added) | target 1.4.5 / 2.12.2 / 2.0.0 | `mix deps.get` / `uv add` |

**Missing dependencies with no fallback:** None block the structural skeleton.
**Missing dependencies with fallback:**
- LLM API credentials — for v0's "does the skeleton feel right" test, a stub Python agent that emits a deterministic JSON action list is enough; wire a real pydantic-ai LLM call once the spine is proven. (This matches the design doc: v0 tests the skeleton, not agent quality.)

## Validation Architecture

> No `.planning/config.json` exists, so `workflow.nyquist_validation` is absent ⇒ treated as ENABLED.

### Test Framework
| Property | Value |
|----------|-------|
| Framework (Elixir) | ExUnit (stdlib, ships with Elixir 1.20.2) — no install |
| Framework (Python) | pytest (add as dev dep) — for the agent's reason+emit logic |
| Config file | `test/test_helper.exs` (Elixir, created by `mix new`); `pyproject.toml [tool.pytest.ini_options]` (Python) |
| Quick run command | `mix test --max-failures 1` |
| Full suite command | `mix test` (+ `uv run pytest` for the Python agent) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| REQ-mount-state | Single-writer GenServer serializes mutations; agent gets snapshot only | unit | `mix test test/agent_os/state_store_test.exs` | ❌ Wave 0 |
| REQ-trigger-time | Scheduler computes next-0700 ms and self-reschedules | unit | `mix test test/agent_os/scheduler_test.exs` | ❌ Wave 0 |
| REQ-hand-input + REQ-propose-enumerated-actions | Port runs wrapper→python, collects JSON, surfaces exit_status | integration | `mix test test/agent_os/port_runner_test.exs` | ❌ Wave 0 |
| REQ-validate-action-vs-grants | Minimal check accepts granted action types, drops/logs ungranted | unit | `mix test test/agent_os/output_check_test.exs` | ❌ Wave 0 |
| REQ-act-on-behalf | Effector mutates state for valid action; agent never does | unit | `mix test test/agent_os/effector_test.exs` | ❌ Wave 0 |
| REQ-restart-policy | Crash once ⇒ retry; crash twice ⇒ supervisor :shutdown ⇒ alert; success ⇒ no re-run | integration | `mix test test/agent_os/run_supervisor_test.exs` | ❌ Wave 0 |
| REQ-list-inventory / REQ-read-run-trace | Inventory renders manifest+last-run; run-log appends a legible line | unit | `mix test test/agent_os/inventory_test.exs` | ❌ Wave 0 |
| REQ-write-manifest + fields | Manifest YAML frontmatter parses into the 7 fields | unit | `mix test test/agent_os/manifest_test.exs` | ❌ Wave 0 |
| REQ-reason-over-input (Python) | Agent reads stdin, emits valid JSON action list, exits 0 | unit | `uv run pytest agents/discovery/` | ❌ Wave 0 |
| Orphan prevention | Killing BEAM mid-run leaves no surviving python | integration/manual | scripted: start run, `kill -9` beam, assert `pgrep -f main.py` empty | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `mix test --max-failures 1` (+ `uv run pytest` if Python touched)
- **Per wave merge:** `mix test` full + `uv run pytest`
- **Phase gate:** Full suite green + the orphan-prevention check + a manual end-to-end "fire the trigger, see a run-log line and an act-on-behalf effect" before `/gsd-verify-work`.

### Wave 0 Gaps
- [ ] `mix new agent_os` — project does not yet have a Mix project (only pyproject.toml exists)
- [ ] `test/test_helper.exs` + per-module test files listed above
- [ ] `pyproject.toml [tool.pytest.ini_options]` + pytest dev dep for the Python agent
- [ ] A test fixture: stub Python agent that emits a fixed JSON action list (decouples skeleton tests from a live LLM)
- [ ] No DB ⇒ the global "dedicated test DB / backups" rule does NOT apply at v0 (term-file/ETS only). Re-evaluate at Phase 3 if a real store is introduced.

## Security Domain

> No `.planning/config.json` ⇒ `security_enforcement` absent ⇒ treated as ENABLED. Note: v0
> explicitly defers REAL enforcement to v2/Phase 3. The relevant v0 security work is structural
> (getting the ring-split shape right), not a hardened boundary.

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V1 Architecture | yes | The user/kernel ring split: agent proposes, substrate acts. Get the *shape* right now even though enforcement is v2. |
| V5 Input Validation | partial | v0 input is hand-fed + unsanitized BY DESIGN (REQ-reason-over-input R1). The minimal output check validates the agent's *output* shape, not web input (that's Phase 2). |
| V6 Cryptography | no | No credentials/secrets handled at v0 (the credential proxy is Phase 3). Never hand-roll when it arrives. |
| V10 Malicious Code / Boundary | yes (structural) | Treat the Python agent as untrusted: it never holds a credential, never mutates state directly, receives a state *snapshot* not the live store. |
| V12 Files/Resources | yes | Agent runs as a local subprocess at v0 (no sandbox until Phase 2). Limit its filesystem reach; don't pass secrets via argv. |

### Known Threat Patterns for this stack
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Agent emits an action outside its grant | Elevation of Privilege | Minimal output check drops/logs ungranted action types (v0); deterministic gate enforces (v2). |
| Orphaned Python process keeps running with access | Elevation / Repudiation | stdin-guard wrapper kills child on boundary close; Phase 2 containerizes. |
| Prompt-injected input biases the agent | Tampering | OUT OF SCOPE at v0 (unsanitized by design); conformance auditor + isolation address it later. Document the known gap. |
| Untrusted agent reads/writes substrate state directly | Tampering | Agent gets a snapshot; only the single-writer GenServer mutates; effector is the sole effect path. |
| Secrets leaked via process argv/env | Information Disclosure | No real secrets at v0; when added (Phase 3) inject at the chokepoint, never via argv. |

## Sources

### Primary (HIGH confidence)
- `docs/agent-os-design.md` — full architecture, principles, roadmap, the cross-boundary failure question (§b "Runtime substrate").
- `.planning/intel/{decisions,constraints,context}.md` — extracted decisions/constraints.
- hexdocs Port (https://elixir.hexdocs.pm/Port.html) — `:spawn_executable`, `:args`, `{port,{:data,_}}` / `{port,{:exit_status,_}}` messages, orphan caveat, wrapper recommendation. [VERIFIED]
- hexdocs Supervisor (https://hexdocs.pm/elixir/Supervisor.html) — `:transient`/`:temporary`/`:permanent`, `max_restarts`/`max_seconds`, `:shutdown` on intensity exceeded. [VERIFIED]
- hex.pm API — verified current versions: muontrap 1.8.0, quantum 3.5.3, yaml_elixir 2.12.2, jason 1.4.5, erlexec 2.3.4. [VERIFIED 2026-06-27]
- pypi — pydantic-ai 2.0.0, pydantic 2.13.4. [VERIFIED 2026-06-27]
- Local toolchain — Elixir 1.20.2, OTP 29, Python 3.14.6. [VERIFIED]

### Secondary (MEDIUM confidence)
- tonyc.github.io "Managing External Commands in Elixir with Ports" — `:exit_status`, `trap_exit`, wrapper pattern.
- MuonTrap README (github.com/fhunleth/muontrap) — containment, cgroups, "not great for interactive programs."
- elixirforum threads — erlexec kill semantics, Porcelain discouraged.
- quantum-core README + victorbjorklund.com — Quantum vs Process.send_after tradeoffs.
- yaml_elixir README — frontmatter split + parse pattern.

### Tertiary (LOW confidence)
- General ecosystem opinion on Porcelain being unmaintained (consistent across multiple forum posts; not from an official deprecation notice).

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all versions verified against hex.pm/pypi today; toolchain verified locally.
- Architecture (boundary, supervision, single-writer): HIGH — verified against official Port/Supervisor docs and corroborated across sources; the design doc locks the shape.
- Scheduler/persistence/tz choices: MEDIUM — sound v0 recommendations but genuine judgment calls (see Assumptions).
- Pitfalls: HIGH for orphan/exit-status/restart semantics; MEDIUM for OOM-in-container (explicitly Phase 2's verification).

**Research date:** 2026-06-27
**Valid until:** ~2026-07-27 (stable libs; pydantic-ai 2.x is the fastest-moving — recheck if planning slips a month).
