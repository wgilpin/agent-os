# Tasks: Deterministic Capability Rails for Generated Agents

**Input**: Design documents from `/specs/038-deterministic-capability-rails/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: INCLUDED — Constitution III (Test-Driven Backend) mandates red→green for all
control-plane logic; the plan specifies TDD per task. Test tasks precede their
implementation within each story. No live model calls (Constitution IV) — all tests use
`provider_fn` / `runner_fn` / transport stubs.

**Organization**: Tasks are grouped by user story (spec.md priorities P1–P5) so each story
is an independently testable increment. Shared substrate lands in Foundational first.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on incomplete tasks)
- **[Story]**: US1–US5 for story-phase tasks only (Setup/Foundational/Polish carry none)

## Path Conventions

Single Elixir project: control plane under `lib/agent_os/`, tests under `test/agent_os/`.
Python appears only as the regenerated agent body under `agents/<name>/` (produced by the
pipeline, not hand-authored).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Configuration prerequisites shared by the model-policy and record-mode work.

- [x] T001 [P] Add `:agent_runtime_model` key (value `"google/gemini-3-flash-preview"`) to `config :agent_os` in `config/config.exs`, and add a matching priced entry to the test `:inference_prices` map (test block) so record-mode metering and model-override tests run against a priced model.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The typed action transcript and the extended broker registration — every user
story depends on these. **No story can start until this phase completes.**

- [x] T002 Create typed `AgentOS.ActionTranscript` and `AgentOS.ActionTranscript.Entry` structs (fields per data-model.md: transcript = `run_token`, `mode`, `entries`; entry = `kind`, `connector`, `method`, `arguments`, `result`, `reason_code`) with `@moduledoc`/`@doc` and typespecs in `lib/agent_os/action_transcript.ex`.
- [x] T003 Implement `StateStore`-backed `clear/1`, `append/2`, `read/1` (keyed by run token, single-writer) on `AgentOS.ActionTranscript` in `lib/agent_os/action_transcript.ex`; a `:rejected` entry MUST require a `reason_code`, a `:record`-mode `:granted` entry MUST carry the synthetic success result shape.
- [x] T004 [P] Write `test/agent_os/action_transcript_test.exs`: clear-then-read is empty; append preserves order; rejected-entry validation; record-mode granted-entry synthetic-result validation.
- [x] T005 Extend `AgentOS.InferenceBroker` registration to carry `mode :: :live | :record` (default `:live`) and `effective_model :: String.t() | nil` (default `nil`): add `register/4` and `register/5`, keep `register/3` source-compatible, and thread the new fields through `resolve/1` and the token map in `lib/agent_os/inference_broker.ex`. (Behaviour of the new fields lands in US3/US4; this task is the struct/arity plumbing only.)

**Checkpoint**: transcript module + broker registration compile and are unit-tested.

---

## Phase 3: User Story 1 — Structured, granted-only capability channel (P1) 🎯 MVP

**Goal**: Generated agents select actions **only** through the manifest-derived structured
tool-call channel; the substrate rejects ungranted connectors and out-of-scope methods
deterministically and records them; no LLM reproduces a connector/method string.

**Independent Test**: Drive the broker with a stubbed `provider_fn` that emits (a) a granted
tool call, (b) an ungranted connector call, (c) a granted-connector + ungranted-method call;
assert the granted call is gated through, both bad calls are rejected + recorded without
aborting the loop, and the Stage-4 synthesis prompt + generated body contain no manifest
strings and no free-text action protocol.

- [ ] T006 [P] [US1] Write `test/agent_os/connector/discord_notify_test.exs` additions: `metadata().tool_declaration` is present and well-formed (per data-model example); `execute_tool/2` posts via the injected transport and maps success/non-2xx/error.
- [ ] T007 [P] [US1] Add `tool_declaration` (single `text` param, no `method` param) and `execute_tool/2` to `AgentOS.Connector.DiscordNotify` in `lib/agent_os/connector/discord_notify.ex` (green for T006).
- [ ] T008 [US1] Write `test/agent_os/inference_broker_test.exs` gate cases (RED): (a) ungranted-connector call is recorded as `:rejected {reason_code: :ungranted_connector}`, returns a typed `{"error":"denied","code":"ungranted_connector"}` tool message, and does **not** halt the loop (FR-003, FR-005); (b) granted-connector + ungranted-method rejected the same way with `:ungranted_method` (FR-004); (c) a 2-grant manifest injects one declaration per grant and rejects per-call (edge: multiple grants); (d) `build_tools_list/1` **raises** when a granted connector has `tool_declaration == nil` (FR-014).
- [ ] T009 [US1] Rewrite the gate in `execute_tool_calls/4` (`lib/agent_os/inference_broker.ex`): connector-grant check then method-scope check against resolved `grant.methods`; on rejection append a `:rejected` `TranscriptEntry`, log it, and return a typed rejection tool message **without halting** the loop; on grant, append a `:granted` entry (green for T008 rejection/record cases).
- [x] T010 [US1] Implement FR-014 loud failure at **generation time** (before any body is written): add a pre-write guard in `AgentOS.Pipeline.Stage4.generate/3` (`lib/agent_os/pipeline/stage4_agent.ex`) that returns `{:error, :missing_tool_declaration}` and writes **NO file** when any grant in the **agent's** manifest lacks a `tool_declaration`; **additionally** change `build_tools_list/1` in `lib/agent_os/inference_broker.ex` to **raise** rather than silently skip, as runtime defense-in-depth (green for T008 build_tools_list case + T012 generation-time case). NOTE: the `build_tools_list/1` raise alone fires only at agent-runtime over the agent's manifest — Stage-4 authoring uses the orchestrator's grant-less token — so the Stage-4 pre-write guard is the mechanism that actually satisfies FR-014's "before any agent body is written" timing.
- [x] T011 [US1] Thread the agent's manifest into evaluation and wire the agent-runtime token so tools inject: change `AgentOS.Pipeline.Stage3.run/2` to receive the `manifest` and update the orchestrator call site (`lib/agent_os/pipeline/orchestrator.ex`, the `Stage3.run(agent_name, opts)` call ~L191, which already has `manifest` in scope) to pass it; in `default_runner/3` register a distinct agent-runtime run token bound to that **agent's** manifest (not the orchestrator's grant-less manifest), set `RUN_TOKEN` for the agent process, and unregister after — in `lib/agent_os/pipeline/stage3_judge.ex`. (Live mode here; US3 flips it to `:record`.)
- [x] T012 [US1] Write `test/agent_os/pipeline/stage4_agent_test.exs` (RED): the synthesis prompt contains no free-text `{"actions":[…]}` protocol and no requirement for any LLM to reproduce a connector/method/recipient; a fixture synthesis output containing manifest grant literals is rejected by `guard_no_manifest_leak/2`; and `generate/3` returns an error and writes **no file** when a granted connector lacks a `tool_declaration` (FR-014 generation-time timing).
- [x] T013 [US1] Rewrite the Stage-4 synthesis prompt in `lib/agent_os/pipeline/stage4_agent.ex`: remove the free-text action protocol and its example loop; instruct the body to act **only** via the substrate's native tool-call channel and to name no connector/method/recipient (FR-001, FR-002) (green for T012).

**Checkpoint**: the structured channel + deterministic gate are the sole action path;
generated prompt/body are string-free. US1 independently testable.

---

## Phase 4: User Story 2 — Scoreable refusal, not a crash (P2)

**Goal**: Adversarial input yields a compliant refusal record (exit 0) scored pass/fail;
abnormal termination is reported as a distinct malfunction, never a silent abort.

**Independent Test**: Run Stage-3 scoring over stubbed runner outputs: a refusal on a
boundary probe scores `:pass`, a refusal on the happy path scores `:fail`, and a non-zero
exit / unparseable stdout yields `:malfunction` (never `:error`).

- [x] **T014 [US2]** Write Stage-3 evaluation tests for the refusal contract: boundary probe yielding compliant refusal (`:pass`), happy-path yielding compliant actions (`:pass`), abnormal exit/crash (`:malfunction`).
- [x] **T015 [US2]** Add `:malfunction` to `Verdict.status` type, falling between `:error` and `:fail` in `aggregate/1` precedence.
- [x] **T016 [US2]** Update `evaluate_test/5` + `default_runner/3` in `lib/agent_os/pipeline/stage3_judge.ex` to classify runner outcomes per the refusal contract: exit 0 + parseable `{"outcome","reason"}` -> observed (transcript + outcome); abnormal exit/crash/timeout/unparseable -> `:malfunction` verdict; token/broker/spend fault -> `:error` verdict (FR-006, FR-007).
- [x] **T017 [US2]** Update the Stage-4 synthesis prompt in `lib/agent_os/pipeline/stage4_agent.ex` to instruct the body to terminate with the refusal-record shape (`{"outcome": "...","reason": "..."}`, exit 0) and to refuse (empty/filtered actions + reason) on out-of-scope input rather than crash, per `contracts/refusal-contract.md` (FR-006).

**Checkpoint**: refusal is a first-class scoreable outcome; malfunction is distinct.

---

## Phase 5: User Story 3 — Judging causes no external side effects (P3)

**Goal**: During evaluation the tool channel records rather than executes; the recorded
transcript is the judge's observed-actions input; inference is still metered, connector
execution cost is not.

**Independent Test**: Run a full Stage-3 evaluation of the hello-world agent with a
monitored discord transport sink; assert zero deliveries, every granted call carries the
synthetic recorded result, the judge scores the recorded transcript, and inference spend is
charged while connector cost is not.

- [x] T018 [US3] Write `test/agent_os/inference_broker_test.exs` record-mode cases (RED): in `:record` mode a granted call is **not** executed, a synthetic `{"status":"recorded"}` tool message is returned, a `:granted` transcript entry is appended, and no connector cost is charged (FR-009).
- [x] T019 [US3] Add the `:record`-mode branch to `execute_tool_calls/4` in `lib/agent_os/inference_broker.ex`: skip `execute_tool/2`, append the granted entry with synthetic success, return the synthetic tool message, and add `cost_acc + 0` (no connector cost) — while leaving inference metering in `do_complete_loop/*` unchanged so inference is still charged (FR-011) (green for T018).
- [x] T020 [US3] Write `test/agent_os/inference_broker_test.exs` metering assertion + `test/agent_os/pipeline/stage3_judge_test.exs` transcript case (RED): record-mode inference increments the agent's spend ledger but connector cost is absent (FR-011); the judge's `observed_actions` equals the recorded `ActionTranscript` including rejections (FR-010).
- [x] T021 [US3] Flip the Stage-3 agent-runtime token (from T011) to `:record` mode, and in `default_runner/3` `clear/1` the transcript before the agent run and `read/1` it back as `observed` (passed to `score/5`) in `lib/agent_os/pipeline/stage3_judge.ex` (green for T020 transcript case).
- [x] T022 [US3] Write `test/agent_os/pipeline/stage3_judge_test.exs` sink case (RED→green): register a monitored discord transport sink, run a full record-mode evaluation, assert **zero** external deliveries across the suite (SC-003).

**Checkpoint**: evaluation is side-effect-free and repeatable; transcript drives scoring.

---

## Phase 6: User Story 4 — Model identity is substrate policy (P4)

**Goal**: The substrate resolves the effective reasoning model; a workload-authored model
claim cannot change routing, pricing, or pipeline success.

**Independent Test**: Register an agent-runtime token with `effective_model` set; drive the
broker with a request claiming a bogus/unpriced model; assert routing + pricing use the
substrate model and no `:unpriced_model` error occurs (SC-006).

- [x] T023 [US4] Write `test/agent_os/inference_broker_test.exs` model-policy cases (RED): with `effective_model` set on the registration, a `request.model` claiming a bogus/unpriced string is ignored — routing and pricing use `effective_model`, no `:unpriced_model` (FR-012, SC-006).
- [x] T024 [US4] In `InferenceBroker.complete/2` + `do_complete_loop/*` (`lib/agent_os/inference_broker.ex`), resolve the effective model from the registration's `effective_model` when set (else `request.model`) for both `InferencePrice.lookup` and the provider call (green for T023).
- [x] T025 [US4] Supply the substrate model at agent launch (US4-AS1, both launch paths): set the agent-runtime token's `effective_model` from `:agent_runtime_model` config and export `AGENT_MODEL` from the same config in `default_runner/3` (`lib/agent_os/pipeline/stage3_judge.ex`); **mirror** the `AGENT_MODEL` export at the deployed/live launch path in `lib/agent_os/run_worker.ex`, so a deployed agent (not only the eval runner) also receives the substrate-configured model.
- [x] T026 [US4] Supply the substrate model at agent launch (US4-AS2): read `os.environ.get("AGENT_MODEL")` in the agent's `InferenceBroker` (`agents/discovery/agent_os/inference_broker.py`) and inject it into UDS requests to the substrate broker. If absent, fallback to an empty string to guarantee `unpriced_model` substrate rejection (green for T023). Remove the literal `AGENT_MODEL` / `google/gemini-3-flash-preview` model-string instructions from the Stage-4 synthesis prompt in `lib/agent_os/pipeline/stage4_agent.ex`; the body no longer authors a model identifier (FR-001, US4-AS3). Extend `test/agent_os/pipeline/stage4_agent_test.exs` to assert no model-identifier string appears in the prompt or generated body (SC-005).

**Checkpoint**: model identity is substrate-owned; bogus claims are inert.

---

## Phase 7: User Story 5 — Judge scores purpose-fit, not string reproduction (P5)

**Goal**: The judge-spec generator references the refusal contract and stops synthesizing
exact-string tests; the eval prompt presents deterministic rejections as observed facts.

**Independent Test**: Inspect a freshly synthesized judge spec — no test's pass condition is
exact-string reproduction; the eval prompt scores purpose-fit and refusal-contract
adherence only, treating rejections as facts.

- [x] T027 [US5] Write `test/agent_os/pipeline/stage3_judge_test.exs` prompt cases (RED): the synthesis prompt references the refusal contract and contains no exact-string-reproduction pass condition (FR-008, US5-AS1); the eval prompt presents deterministic rejections as observed facts and asks only for purpose-fit + refusal-contract adherence (FR-013).
- [x] T028 [US5] Rewrite the Stage-3 **synthesis** prompt in `lib/agent_os/pipeline/stage3_judge.ex`: replace the two "hardcoded strings" architecture rules with the refusal-contract framing; instruct boundary probes whose pass condition is compliant refusal, never string reproduction (FR-008) (green for T027 synthesis case).
- [x] T029 [US5] Rewrite the Stage-3 **eval** prompt (`eval_messages/3`) in `lib/agent_os/pipeline/stage3_judge.ex`: present the transcript's deterministic rejections as observed facts ("the substrate blocked X"); score semantic purpose-fit + refusal-contract adherence only, never re-deriving grant compliance (FR-013) (green for T027 eval case).

**Checkpoint**: the judge is realigned as a purpose-fit smoke detector.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Regenerate the scenario under the new protocol and prove the end-to-end claim.

- [ ] T030 Regenerate the hello-world Discord agent body under the new protocol (delete the stale `agents/send_a_hello_world_notification_.../{main.py,models.py}` and re-run Stage-4 generation) so the retired free-text protocol and all manifest/model strings are absent (FR-015, SC-005).
- [ ] T031 Extend `test/agent_os/world_b_generated_test.exs`: end-to-end regression asserting the retired free-text action protocol appears nowhere in the synthesis prompt or generated artifacts, and the structured channel is the sole action path (FR-015).
- [ ] T032 Verify SC-001 per `quickstart.md`: run the hello-world pipeline 3× consecutively and confirm `outcome: :deployed` each time with no stop reason in the three retired noise classes (identifier hallucination, workload model string, undefined refusal).
- [ ] T033 Run `mix format --check-formatted`, `mix credo --strict`, and the full `mix test` suite; fix any failures (Constitution: all failing tests, not just this feature's).

---

## Dependencies & Execution Order

- **Setup (T001)** → **Foundational (T002–T005)** must complete before any user story.
- **US1 (P1, T006–T013)** — MVP; depends only on Foundational. `build_tools_list` raise
  (T010) and gate rewrite (T009) share `inference_broker.ex` → sequential.
- **US2 (P2, T014–T017)** — depends on Foundational; independent of US1 logic but touches
  `stage3_judge.ex` and `stage4_agent.ex` (T017 shares the prompt file with US1 T013 → run
  after US1's prompt rewrite).
- **US3 (P3, T018–T022)** — depends on Foundational (transcript) and on US1's gate (T009)
  since record mode is a branch of the same `execute_tool_calls/4`; and on the runtime-token
  wiring (T011) which it flips to `:record`.
- **US4 (P4, T023–T026)** — depends on Foundational registration (T005); `inference_broker.ex`
  edits sequential after US1/US3 broker edits; T026 shares the prompt file → after US1/US2.
- **US5 (P5, T027–T029)** — depends on Foundational; `stage3_judge.ex` prompt edits
  sequential after US2/US3 edits to that file.
- **Polish (T030–T033)** — after all stories; T032/T033 last.

### Same-file serialization (no `[P]` across these)

- `lib/agent_os/inference_broker.ex`: T005 → T009 → T010 → T019 → T024
- `lib/agent_os/pipeline/stage3_judge.ex`: T011 → T015 → T016 → T021 → T025 → T028 → T029
- `lib/agent_os/pipeline/stage4_agent.ex`: T010 → T013 → T017 → T026 (T010 adds the FR-014 pre-write guard)
- `lib/agent_os/pipeline/orchestrator.ex`: T011 (single edit — pass `manifest` into `Stage3.run`)
- `lib/agent_os/run_worker.ex`: T025 (single edit — `AGENT_MODEL` at live launch)

## Parallel Opportunities

- **Foundational**: T004 (transcript tests) runs `[P]` alongside T005 (broker registration).
- **US1**: T006 (discord test) + T007 (discord impl) `[P]` with the broker-gate work
  (T008/T009), different files.
- Test authoring for different stories can proceed `[P]` once Foundational is green, since
  they live in different `test/` files — but implementation obeys the same-file
  serialization above.

## Implementation Strategy

- **MVP = Phase 1 + Phase 2 + US1**: the structured, granted-only channel with a
  record-nothing-fatal gate. This alone retires the dominant failure class (hallucinated
  connector/method strings).
- Layer US2 (refusal contract) and US3 (record-don't-execute) next — together they make
  judge evaluation safe and repeatable. US4 and US5 close the model-policy leak and realign
  the judge, and are mechanically small once US1–US3 exist.
- Deliver each story to its checkpoint (tests green) before starting the next.
