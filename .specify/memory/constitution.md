# Agent OS Constitution

Agent OS is a deterministic BEAM/OTP control plane (the kernel) that declares,
enforces, observes, and supervises invocation-scoped agent processes. This is a
prototype to learn whether the architecture feels right — not a production system.
The principles below are binding on every spec, plan, and implementation.

## Core Principles — Engineering Practice

### I. Simplicity First — Prototype, Not Production (NON-NEGOTIABLE)
Always reach for the simplest thing that works: standard library before dependencies,
one function before a framework, YAGNI by default. This is a demo/prototype; complexity
must be justified against this principle, never the reverse.

### II. Explicit Scope Control (NON-NEGOTIABLE)
Never add a feature, capability, abstraction, or dependency beyond what was explicitly
requested without checking first. "While I was here" changes are a violation. When in
doubt, ask before building.

### III. Test-Driven Backend
Backend services and logic are built test-first: red → green → refactor. Do NOT write
unit tests for frontend components or API endpoints — those are covered by manual
walkthrough or integration checks, not unit tests.

### IV. No Live Dependencies in Tests (NON-NEGOTIABLE)
Tests never call remote APIs — mock them. If a test's value depends on a live remote
API (e.g. an LLM call), do not write it: it asserts nothing deterministic. This is why
the discovery agent ships a deterministic stub, not a live model, for tests.

### V. Strong Typing, No Bare Maps
Every function argument and return is strongly typed.
- **Python workloads:** Pydantic models or TypedDicts — never plain dicts. Avoid `Any`.
  `mypy` must pass.
- **Elixir control plane:** typespecs + structs over bare maps where practical; Dialyzer
  clean.
Prefer a functional style over OOP everywhere.

### VI. Loud Failures
Comprehensive logging throughout. There are NO silent exceptions — every caught
exception logs with enough context to diagnose it. A swallowed error without a log is a
defect.

### VII. Self-Documenting Through Comments
Every function carries at least a one-line statement of what it is for — Python
docstrings, Elixir `@doc`/`@moduledoc`. Every substantial code block carries an inline
comment explaining its intent: the *why* and the *what*, not a restatement of the syntax.
Trivial one-liners need no ceremony, but no non-obvious logic ships uncommented.

## Core Principles — Architectural Invariants

These encode the control-plane thesis. The planner must treat them as locked and never
re-litigate them per feature.

### VIII. Legibility Is Non-Negotiable (the principle with no flag)
The system always presents a standing inventory of what exists and a legible trace of
what it did, read WITHOUT asking the agent. If only one principle survives, this is it.

### IX. The Substrate Owns State & Lifecycle
The substrate owns all persistent state and all scheduling. Single writer per mutable
store (roster/trust = a single-writer GenServer mutated only via messages; the
append-only digest = git-backed markdown; no external database). Agents are
invocation-scoped pure functions that run once and die — "looping" is a trigger
re-invoking them, never a long-lived process.

### X. No Ambient Authority
An agent's manifest grants are its entire power — capability-based in the seL4 sense.
The declarative manifest is the single source of truth, and it is privileged-read for
the gate only: NOT readable by the agent at all (the agent is the untrusted party).

### XI. The Deterministic Gate Is the Only Firewall (NON-NEGOTIABLE)
No component both runs an LLM and holds a credential that can mutate external state.
Privileged action is deterministic, on the agent's behalf, after a gate check. LLM
review layers (security-review, conformance-auditor) are smoke detectors, never
sprinklers — they can raise a flag, never grant a pass that crosses the gate.

### XII. Enforcement Precedes Generation (HARD ordering)
Manifest enforcement (v2) MUST precede agent generation (v3). Enforcement earns trust on
easy mode (human authors) before generation makes it load-bearing. This ordering cannot
be reshuffled.

## Tech Stack & Tooling

- **Control plane:** Elixir/BEAM (OTP supervisors, single-writer state-owners, ports).
  `mix format` + Credo clean before saving.
- **Agent workloads:** Python, managed with `uv`, executed across the port/HTTP boundary.
  `ruff` must pass before any file is saved; `mypy` clean. A Python crash/OOM must surface
  to its BEAM supervisor as a clean process exit.
- **Storage:** term-file (single-writer GenServer) + git-backed append-only markdown. No
  external database.
- **Models:** Gemini must be 3-series (e.g. `gemini-3-flash-preview`), never 2-series.
  Default to the latest, most capable model for whichever provider is in use.

## Quality Gates

- Linters/formatters pass before save: `ruff` (Python), `mix format` + Credo (Elixir).
- `mypy` clean for Python.
- TDD followed for backend logic; no remote API calls in any test.
- Every function has a purpose comment/docstring; substantial blocks are commented.
- New scope confirmed with a human before implementation.

## Governance

This constitution supersedes ad-hoc practice. Amendments are documented with a rationale
and a version bump. Any complexity or deviation must be justified against Principle I.
Specs, plans, and reviews verify compliance with these principles; an unjustified
violation blocks the change.

**Version**: 1.1.0 | **Ratified**: 2026-06-28 | **Last Amended**: 2026-06-28
```