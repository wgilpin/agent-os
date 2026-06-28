---
phase: 1
slug: walking-skeleton-v0
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-27
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ExUnit (Elixir, stdlib — ships with Elixir 1.20.2, no install) + pytest (Python agent, dev dep) |
| **Config file** | `test/test_helper.exs` (created by `mix new`); `pyproject.toml [tool.pytest.ini_options]` (Python) |
| **Quick run command** | `mix test --max-failures 1` (+ `uv run pytest` if Python touched) |
| **Full suite command** | `mix test` + `uv run pytest` |
| **Estimated runtime** | ~15 seconds (skeleton scope; agent stubbed, no live LLM) |

---

## Sampling Rate

- **After every task commit:** Run `mix test --max-failures 1` (+ `uv run pytest` if the Python agent was touched)
- **After every plan wave:** Run `mix test` full + `uv run pytest`
- **Before `/gsd-verify-work`:** Full suite green + the orphan-prevention check + a manual end-to-end "fire the trigger, see a run-log line and an act-on-behalf effect"
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 1-01-xx | 01 | 1 | REQ-mount-state | T-1-04 | Only single-writer GenServer mutates; agent gets snapshot only | unit | `mix test test/agent_os/state_store_test.exs` | ❌ W0 | ⬜ pending |
| 1-02-xx | 02 | — | REQ-trigger-time | — | Scheduler computes next-0700 ms and self-reschedules | unit | `mix test test/agent_os/scheduler_test.exs` | ❌ W0 | ⬜ pending |
| 1-02-xx | 02 | — | REQ-write-manifest, REQ-state-purpose, REQ-grant-connectors-mounts, REQ-set-spend-cap | — | Manifest YAML frontmatter parses into the 7 fields | unit | `mix test test/agent_os/manifest_test.exs` | ❌ W0 | ⬜ pending |
| 1-03-xx | 03 | — | REQ-hand-input, REQ-propose-enumerated-actions, REQ-instantiate-from-declaration | T-1-02 | Port runs wrapper→python, collects JSON, surfaces exit_status; no orphan | integration | `mix test test/agent_os/port_runner_test.exs` | ❌ W0 | ⬜ pending |
| 1-03-xx | 03 | — | REQ-reason-over-input | T-1-03 | Python agent reads stdin, emits valid JSON action list, exits 0 | unit | `uv run pytest agents/discovery/` | ❌ W0 | ⬜ pending |
| 1-04-xx | 04 | — | REQ-validate-action-vs-grants | T-1-01 | Minimal check accepts granted action types, drops/logs ungranted | unit | `mix test test/agent_os/output_check_test.exs` | ❌ W0 | ⬜ pending |
| 1-04-xx | 04 | — | REQ-act-on-behalf | T-1-04 | Effector mutates state for valid action; agent never does | unit | `mix test test/agent_os/effector_test.exs` | ❌ W0 | ⬜ pending |
| 1-05-xx | 05 | — | REQ-list-inventory, REQ-read-run-trace | — | Inventory renders manifest+last-run; run-log appends a legible line | unit | `mix test test/agent_os/inventory_test.exs` | ❌ W0 | ⬜ pending |
| 1-05-xx | 05 | — | REQ-restart-policy | — | Crash once ⇒ retry; crash twice ⇒ supervisor :shutdown ⇒ alert; success ⇒ no re-run | integration | `mix test test/agent_os/run_supervisor_test.exs` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `mix new agent_os` — no Mix project exists yet (only `pyproject.toml` is present)
- [ ] `test/test_helper.exs` + per-module test files listed above
- [ ] `pyproject.toml [tool.pytest.ini_options]` + pytest dev dep for the Python agent
- [ ] Test fixture: a stub Python agent that emits a fixed JSON action list (decouples skeleton tests from a live LLM)
- [ ] No DB at v0 (term-file / ETS only) ⇒ the global "dedicated test DB / backups" rule does NOT apply this phase. Re-evaluate at Phase 3 if a real store is introduced.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Orphan prevention | REQ-instantiate-from-declaration (boundary) | Requires killing the BEAM mid-run and inspecting OS process table | Start a run, `kill -9` the beam process, assert `pgrep -f main.py` returns empty |
| End-to-end skeleton "feel" | Phase goal (structural) | The phase's real success criterion is subjective — "does the one-supervisor / one-store / one-port skeleton feel right?" | Fire the trigger manually; confirm a legible run-log line appears and an act-on-behalf effect lands in state |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
