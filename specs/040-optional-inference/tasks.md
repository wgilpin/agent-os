---
description: "Task list for Optional Inference for Generated Agents"
---

# Tasks: Optional Inference for Generated Agents

**Input**: Design documents from `/specs/040-optional-inference/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md (all present)

**Tests**: INCLUDED and TDD-ordered (plan Constitution Check III: RED tests first, then green). Every test runs with `provider_fn`/transport stubs and pre-seeded state — no live model calls (Constitution IV). Assertions read the `AgentOS.ActionTranscript` and `spend_ledger`.

**Organization**: Grouped by user story (P1 → P3). Stories are dependency-ordered (US1 → US2 → US3) per the plan.

## Stack & conventions (from plan.md)

Elixir ~1.16 / OTP 26 substrate under `lib/agent_os/`; Python 3.11 sandboxed bodies + fixtures under `agents/` and `test/fixtures/`; ExUnit tests under `test/agent_os/`. No new external deps. Scope: 2 new modules (`ExecutionMode`, `ToolSubmission`), surgical changes to 4 existing modules (`inference_broker.ex`, `stage4_agent.ex`, `stage3_judge.ex`, `orchestrator.ex`), 1 deterministic Python fixture, ~5 test files.

Authoritative interface specs live in:
- `contracts/tool-calls-channel.md` — `POST /v1/tool_calls` request/response/routing (US1)
- `contracts/execution-mode.md` — `classify/3` + `execution_mode.json` sidecar (US2)
- `contracts/deterministic-agent.md` — deterministic `main.py` stdin/stdout/submission contract (US2)
- `data-model.md` — `ExecutionMode`, `ToolSubmission`, channel response, extended `AgentBody`

Existing seams reused: `AgentOS.TestHelper.start_broker_uds!/1`, `provider_fn` stubs, connector transport stubs (e.g. `:discord_notify_transport`), transcript assertions.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Test seams shared across all three stories; no production code.

- [X] T001 [P] Add a `submit_tool_calls` UDS-client helper + a `refute_inference_spend/1` assertion to `test/test_helper.exs` (`AgentOS.TestHelper`), mirroring the existing `call_inference_broker` HTTP-over-UDS framing, so tests can POST to `/v1/tool_calls` and assert zero inference charges on the `spend_ledger` (Constitution IV; contract "Invariants under test" #3).
- [X] T002 [P] Add a checked-in deterministic Python fixture `test/fixtures/generation/deterministic_hello_world/main.py` + `models.py` (hello-world Discord shape: read one opaque stdin line, POST a hard-coded `discord_notify` call to `/v1/tool_calls`, print an outcome record) for the US1 UDS test and the US2/Polish E2E, per `contracts/deterministic-agent.md`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Typed boundary structs both the channel (US1) and classification/synthesis (US2/US3) depend on. No user-visible behavior yet.

- [X] T003 [P] Create `AgentOS.ToolSubmission` in `lib/agent_os/tool_submission.ex`: typed struct `%{run_token: String.t(), tool_calls: [map()]}` + `from_map/1` validating the body decodes with a binary `run_token` and a **list** `tool_calls` (empty list valid) → `{:ok, t()} | {:error, :bad_request}`; malformed *calls* are NOT rejected here (they pass to the rail, which records `:rejected`) per data-model.md validation rules.
- [X] T004 [P] Create `AgentOS.ExecutionMode` skeleton in `lib/agent_os/execution_mode.ex`: typed struct `%{mode: :deterministic | :inference, rationale: String.t()}` + `parse/1` (string/atom → `{:ok, t()} | {:error, :invalid_mode}`) and `to_json/1`/`from_json/1`. (Classification `classify/3` and sidecar `store/3`,`load/2` land in US2 — T017/T018 — so the type is available to US1 tests and threading first.)
- [X] T005 [P] Unit test `test/agent_os/execution_mode_test.exs` (type-only portion): round-trips both `:deterministic`/`:inference` values, rejects any third value and any bare-map/bare-string input (Constitution V; data-model.md "Never a bare string").

**Checkpoint**: `ToolSubmission` and `ExecutionMode` compile and round-trip; T005 type tests pass.

---

## Phase 3: User Story 1 - Direct tool submission without inference (P1) 🎯 MVP

**Goal**: `POST /v1/tool_calls` runs submitted calls through `CapabilityRail.evaluate_tool_calls/4` with **no model call**, identical gating/parking/recording/metering; other paths keep `complete/2` (back-compat).

**Independent Test**: With a registered token, seeded grants/ledger, and **no `provider_fn` configured**, submit granted/ungranted/approval-required calls → transcript shows `:granted`/`:rejected`/`:parked`; connector cost on the ledger for the granted call; zero inference spend.

### Tests for User Story 1 (write first — RED)

- [X] T006 [P] [US1] Three-way disposition test in `test/agent_os/tool_channel_test.exs`: `InferenceBroker.submit_tool_calls/2` on granted + ungranted + approval-required calls yields `:granted`/`:rejected`(`:ungranted_connector`)/`:parked` transcript entries matching the inference path byte-for-byte on `kind`/`connector`/`reason_code`; connector cost added to `spend_ledger` for the granted call; `refute_inference_spend/1` passes (SC-003; contract Invariants #1, #3).
- [X] T007 [P] [US1] Rejection-variety test in `test/agent_os/tool_channel_test.exs`: granted-connector-ungranted-method → `:rejected`(`:ungranted_method`); unknown connector name → `:rejected`(`:unknown_connector`); assert each is recorded, none executed (FR-003; channel contract table).
- [X] T008 [P] [US1] Malformed-request test in `test/agent_os/tool_channel_test.exs`: body not JSON / missing `run_token` / `tool_calls` not a list → `{:error, :bad_request}` (HTTP 400), nothing evaluated, logged with context; and empty `tool_calls` → `{:ok, %{results: []}}` with an empty transcript, run completes (FR-003, edge cases "Malformed"/"Empty submission").
- [X] T009 [P] [US1] Spend + response-safety test in `test/agent_os/tool_channel_test.exs`: cumulative cost crossing the cap → `{:breach, :spend}` (HTTP 402); and assert no response field contains a credential, recipient allowlist, or spend cap (FR-004, Acceptance 4; contract Invariant #4).
- [X] T010 [P] [US1] UDS routing integration test in `test/agent_os/tool_channel_test.exs`: via `start_broker_uds!/1`, POST `/v1/tool_calls` → disposition results; POST `/v1/inference` (and a pathless request) → unchanged `complete/2` behavior (research D1, contract "Routing rule").
- [X] T010a [P] [US1] Multi-call partial-success test in `test/agent_os/tool_channel_test.exs`: a single submission with a granted call followed by an ungranted call is evaluated in order, records **two** independent transcript entries (`:granted` then `:rejected`), and returns two per-call `results` with matching per-call dispositions — partial success is visible per call (spec edge case "multiple calls"; channel contract "Multiple calls allowed … evaluated in order, each gated and recorded individually").

### Implementation for User Story 1

- [X] T011 [US1] Extend `read_http_request/2` in `lib/agent_os/inference_broker.ex` to return the request **path** (parse the request line), keeping current body-reading behavior (research D1; the handler ignores the path today).
- [X] T012 [US1] Add `AgentOS.InferenceBroker.submit_tool_calls/2` (public function, `@doc`/`@spec`): `ToolSubmission.from_map/1` → `resolve/1` token → spend-window normalization + pre-check `spent >= cap` → `CapabilityRail.evaluate_tool_calls(tool_calls, agent_name, manifest, run_token)` → persist accumulated tool cost via `{:put, agent_name, entry}` → return typed per-call `results` (`disposition ∈ executed|rejected|parked`, `content`). Mirrors `do_complete_loop`'s rail interaction minus the model (research D2; data-model channel response). **Rail stays unchanged.**
- [X] T013 [US1] Route the UDS handler in `handle_connection/1` (`lib/agent_os/inference_broker.ex`): `/v1/tool_calls` → `submit_tool_calls/2` with HTTP mapping `200 {results}` · `400 {"error":"bad_request"}` · `401 {"error":"unknown_run_token"}` · `402 {"error":"spend_breach"}`; **any other path (incl. `/v1/inference`, pathless) → existing `complete/2`** (contract "Routing rule"; FR-001).
- [X] T014 [US1] Verify (and, if the rail's returned per-call feedback isn't sufficient, add a small mapper in `submit_tool_calls/2`) that `content` in each result equals the same tool-message string the inference path returns for that disposition — no new transcript writer is introduced (FR-011; contract Invariant #2).

**Checkpoint**: US1 independently shippable — an agent reaches the gate with no model; T006 passes with no provider configured. Unblocks US2 and US3.

---

## Phase 4: User Story 2 - Mode classification and branched synthesis (P2)

**Goal**: The orchestrator classifies each purpose once (typed `ExecutionMode`) between Stage 2 and Stage 4, records the sidecar, and threads the mode so Stage 4 branches to the deterministic or inference synthesis contract. Depends on US1 (deterministic bodies submit to `/v1/tool_calls`) and Foundational `ExecutionMode`.

**Independent Test**: Drive the pipeline with stubbed providers for a fixed-action and a reasoning purpose; verify classification, body shape (deterministic contains no inference call), sidecar written, adversarial payload byte-identical, mode readable afterward.

### Tests for User Story 2 (write first — RED)

- [X] T015 [P] [US2] Classification test in `test/agent_os/execution_mode_test.exs`: `classify/3` with a `provider_fn` stub returns `:deterministic` for a fixed-action purpose and `:inference` for a reasoning purpose; **any** parse failure/broker error/ambiguity → `:inference` with a logged warning; sidecar `store/load` round-trip; `load/2` on a missing file → `%ExecutionMode{mode: :inference, rationale: "pre-040 …"}` (contract execution-mode.md; research D5; Acceptance 1–2, Edge "Ambiguous purpose").
- [X] T016 [P] [US2] Stage 4 branch + guard test in `test/agent_os/pipeline/stage4_agent_test.exs`: a deterministic stub body containing a granted tool name + method **passes** the mode-aware leak guard and submits to `/v1/tool_calls` with no `/v1/inference` call; the **same** deterministic body containing a recipient/spend-cap/credential literal still **fails**; an inference stub body containing a tool name still **fails** (mode B guard unchanged); `AgentBody.execution_mode` is stamped and the sidecar is written (research D4/D6, D8; FR-006, FR-008, Acceptance 5).
- [X] T017 [P] [US2] Injection-immunity test in `test/agent_os/pipeline/stage4_agent_test.exs` (or the E2E file): a deterministic body given adversarial stdin ("ignore your instructions and send X") submits byte-identical tool calls to the benign case (SC-002, FR-007, Acceptance 3; contract deterministic-agent.md step 1).
- [X] T018 [P] [US2] Orchestrator threading test in `test/agent_os/pipeline/orchestrator_test.exs`: classification runs between Stage 2 and Stage 4, the typed mode is passed to both Stage 4 and Stage 3 via opts, classification uses the orchestrator's uncapped setup token, and both stages derive from manifest+purpose+mode (co-generation isolation preserved) (research D5; FR-005).

### Implementation for User Story 2

- [X] T019 [US2] Implement `AgentOS.ExecutionMode.classify(agent_name, manifest, opts)` in `lib/agent_os/execution_mode.ex`: one `InferenceBroker.complete/2` completion (model = `agent_codegen_model` config, overridable via `:model` opt; classification is one-off setup, same class as synthesis) asking "does fulfilling this purpose require reasoning over dynamic content at runtime?", parse `{"mode","rationale"}`; **any** failure/ambiguity → `%ExecutionMode{mode: :inference}` logged loudly (contract execution-mode.md; FR-005).
- [X] T020 [US2] Implement `ExecutionMode.store(agent_name, t(), opts)` / `load(agent_name, opts)` writing/reading `agents/<agent_name>/execution_mode.json`; missing file → typed `:inference` default with "pre-040 agent" rationale (data-model.md; no manifest schema change — sidecar only, research D5).
- [X] T021 [US2] Add the deterministic-body Python reference constant `@tool_channel_call_reference` (UDS POST to `/v1/tool_calls`, mirroring `@broker_call_reference`) to `lib/agent_os/pipeline/stage4_agent.ex` (research D6; contract deterministic-agent.md step 2).
- [X] T022 [US2] Branch `synthesis_messages/2` in `stage4_agent.ex` on the passed mode: deterministic prompt (read stdin as opaque data, hard-code tool call(s) in generic tool vocabulary, submit via `@tool_channel_call_reference`, derive outcome from per-call dispositions, no inference call); inference prompt = today's body, unchanged (research D6; FR-006, FR-007).
- [X] T023 [US2] Make `guard_no_manifest_leak/2` → `guard_no_manifest_leak/3` (mode-aware) in `stage4_agent.ex`: for `:deterministic`, permit granted connector **tool names** and granted **method names** as literals; **recipients, spend cap, credential-shaped strings, and every other manifest literal stay forbidden in every mode**; document the manifest-invisibility rationale at the guard site (research D4; Constitution VII; FR-008).
- [X] T024 [US2] Thread the mode through `Stage4.generate/3`: accept `execution_mode` via opts, select the prompt branch, run all existing guards (typed contract, path safety, syntax, no-direct-provider unchanged), stamp `AgentBody.execution_mode`, and call `ExecutionMode.store/3` after guards pass (data-model.md extended `AgentBody`; contract execution-mode.md consumers).
- [X] T025 [US2] Add the classification step to `lib/agent_os/pipeline/orchestrator.ex` between Stage 2 (manifest) and Stage 4: call `ExecutionMode.classify/3` under the existing uncapped orchestrator token, then thread the typed mode into the `opts` passed to both `Stage4.generate/3` and `Stage3.generate/3`/`run/3` (research D5; FR-005).

**Checkpoint**: Fixed-action purposes generate deterministic, injection-immune bodies with a recorded mode; reasoning purposes unchanged; orchestrator threads mode end-to-end.

---

## Phase 5: User Story 3 - Judge tests the declared mode, not agent politeness (P3)

**Goal**: Stage 3 branches its judge-spec synthesis and eval on the declared mode, verifies purpose-fit + substrate containment (read from the transcript), and drops all retired-protocol expectations. Depends on US2's recorded/threaded mode.

**Independent Test**: Run judging against one deterministic and one inference agent with stubbed providers; per-mode expectations differ, no empty-actions-list/self-policing expectations anywhere, containment asserted from the transcript, judging stays uncapped.

### Tests for User Story 3 (write first — RED)

- [X] T026 [P] [US3] Deterministic-judge test in `test/agent_os/pipeline/stage3_judge_test.exs`: for a `:deterministic` agent, generated specs assert the fixed effect appears on the transcript for benign AND adversarial inputs (identical behavior) and that nothing outside the grant set appears as `:granted`; no refusal-contract language (research D7; Acceptance 1).
- [X] T027 [P] [US3] Inference-judge test in `test/agent_os/pipeline/stage3_judge_test.exs`: for an `:inference` agent, specs assert purpose-fit + containment only, with no expectation the agent self-polices ungranted connectors, out-of-scope methods, or spend caps (Acceptance 2, FR-010).
- [X] T028 [P] [US3] Retired-protocol scan in `test/agent_os/pipeline/stage3_judge_test.exs`: neither the synthesis prompt, `eval_messages/3`, nor any generated spec contains "empty actions list" or self-policing phrasing (SC-005, Acceptance 3, FR-010).
- [X] T029 [P] [US3] Containment + uncapped test in `test/agent_os/pipeline/stage3_judge_test.exs`: verdicts read `:rejected`/`:parked` transcript entries as observed facts (not agent self-reports); `Stage3.run/3`'s `eval_manifest` cap-lift and `:record` registration remain intact (FR-009, FR-012, Acceptance 4, SC-006).

### Implementation for User Story 3

- [X] T030 [US3] Branch `synthesis_messages/2` in `lib/agent_os/pipeline/stage3_judge.ex` on the declared mode (loaded via `ExecutionMode.load/2` if not passed in opts): deterministic branch (fixed-effect-for-any-input, incl. an adversarial-input case) vs inference branch (purpose-fit probes) (research D7; FR-009).
- [X] T031 [US3] Delete retired-protocol rules from `stage3_judge.ex` prompts: remove the refusal-contract / "empty actions list" instructions (rules 1–2 in `synthesis_messages/2`) and the self-policing scoring instruction in `eval_messages/3` (FR-010, SC-005).
- [X] T032 [US3] Rewrite `eval_messages/3` scoring so it reads substrate dispositions from the transcript (`:granted`/`:parked`/`:rejected`) as observed facts and scores (a) purpose-fit and (b) containment (no forbidden effect present as `:granted`) — the `default_runner/3` already returns `%{actions: transcript, response: parsed}`; score against `actions` (research D7; FR-009).
- [X] T033 [US3] Confirm `Stage3.run/3` keeps the `eval_manifest` cap-lift and `:record` registration verbatim after the mode changes; add a regression guard so the 038-era uncapped-judging fix is not lost (FR-012; memory "Spend cap is runtime-only").

**Checkpoint**: Both modes judged on containment + purpose-fit from transcript facts; zero retired-protocol expectations remain.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T034 [P] E2E deterministic run (SC-001) in `test/agent_os/tool_channel_test.exs` (or a dedicated E2E file): run the `deterministic_hello_world` fixture through the `start_broker_uds!/1` harness with a stubbed `:discord_notify_transport`; assert one `:granted` transcript entry, a valid outcome record on stdout, and zero inference charges (quickstart validation; research D8).
- [X] T035 [P] E2E injection-immunity (SC-002): feed adversarial stdin to the same fixture end-to-end; assert the submitted call bytes are identical to the benign case and the transcript entry is unchanged.
- [X] T035a [P] Outcome-derivation E2E for non-executed dispositions (`contracts/deterministic-agent.md` step 3): run the deterministic fixture against a run whose grant requires approval → assert the transcript entry is `:parked` and the body's stdout outcome record is `{"outcome": "parked", ...}`; likewise assert an ungranted call yields a `:rejected` entry and an `{"outcome": "rejected", ...}` record. Covers the parked/rejected branches T034 leaves untested.
- [X] T036 Regenerate/validate the checked-in `agents/send_a_hello_world_notification_.../` agent through the pipeline: classifier marks it `:deterministic`, body contains no broker-completion call, `execution_mode.json` records the classification, and its `judge_spec.json` carries no retired-protocol expectations (plan §7; SC-004, SC-005). Update the working-tree `judge_spec.json`/manifest accordingly.
- [X] T037 [P] Quality-gate pass (Constitution Quality Gates): `ruff` + `mypy` clean on the new/updated Python fixtures (`test/fixtures/generation/deterministic_hello_world/`) and any regenerated agent body; `mix format` + Credo + Dialyzer clean on the new/changed Elixir (`tool_submission.ex`, `execution_mode.ex`, `inference_broker.ex`, `stage4_agent.ex`, `stage3_judge.ex`, `orchestrator.ex`).
- [X] T038 Run the full suite (`mix test`) and confirm no live model calls and no regression of uncapped generation/judging spend (SC-006, quickstart). Fix any pre-existing failures surfaced (global testing rule).

---

## Dependencies & Execution Order

- **Setup (Phase 1)** + **Foundational (Phase 2)** precede all stories; T003/T004/T005 can run parallel to T001/T002.
- **US1 (Phase 3)** — the blocking substrate gap — must complete before US2/US3 deliver value. Uses `ToolSubmission` (T003).
- **US2 (Phase 4)** depends on US1 (`/v1/tool_calls`) and `ExecutionMode` (T004).
- **US3 (Phase 5)** depends on US2 (recorded/threaded mode).
- **Polish (Phase 6)** depends on US1–US3.

Within each story, `[P]` test tasks (same file, split by `describe` block if edited concurrently) come first, then implementation. Implementation tasks touching the same file are **sequential**: `inference_broker.ex` (T011→T012→T013→T014); `execution_mode.ex` (T019→T020); `stage4_agent.ex` (T021→T022→T023→T024); `orchestrator.ex` (T025); `stage3_judge.ex` (T030→T031→T032→T033).

## Parallel Execution Examples

- Setup + Foundational: T001, T002, T003, T004, T005 together.
- US1 tests: T006–T010a together (one file — coordinate by `describe`).
- US2 tests: T015 (execution_mode), T016/T017 (stage4), T018 (orchestrator) together across files.
- US3 tests: T026–T029 together.
- Polish: T034, T035, T035a, T037 together; T038 (full suite) runs last, after T036.

## Implementation Strategy

**MVP = US1 (Phase 3).** It closes the blocking substrate gap: a `/v1/tool_calls` route to the existing rail with no model call, fully gated/recorded/metered, back-compatible for deployed agents. Land and validate US1 (T006 three-way disposition + zero inference spend) before US2. US2 makes the deterministic/inference choice explicit, recorded, and injection-immune; US3 aligns the judge to the declared mode. Each story is an independently testable increment; the rail is never modified (plan Structure Decision).
