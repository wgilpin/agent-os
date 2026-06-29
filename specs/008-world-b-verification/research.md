# Phase 0 Research: World-B Verification

This plan introduces no new technology. "Research" here resolves the *method* questions a verification
plan must settle before it can be designed: how to prove "regardless of agent code" deterministically,
what counts as proof for each breach class, and where the docker layer sits. Every decision below is
grounded in the existing code and the constitution.

---

## D1 — How do you verify "regardless of agent code" without running hostile agents?

**Decision**: Drive the **enforcement chokepoints with arbitrary hostile *output* constructed in-test**,
not hostile containers. A sandboxed agent's entire power is the output it emits — its proposed-action
batch, the strings on its stdout, the web content it ingests and echoes. The gate, effector, broker,
and trigger intake all sit *downstream* of that output and are agnostic to how it was produced. So a
hostile `ProposedAction` batch built directly in a test is, to the gate, indistinguishable from one a
maximally-malicious agent emitted — and it can express the *worst* output far more exhaustively than a
single hostile binary could.

**Rationale**:
- It makes the world-B claim **universally quantified over agent output** rather than over one example
  agent. We assert "for any proposed batch B, the gate's verdict is safe," which is the actual claim.
- It keeps every assertion **deterministic and free of live dependencies** (Constitution IV): no
  container launch, no network, no model. The default `mix test` run stays hermetic
  (`test_helper.exs` already does `ExUnit.start(exclude: [:docker])`).
- The chokepoints already accept injected effects (`effector_fn`, `provider_fn`, `:now`), so a hostile
  scenario needs no production change.

**Alternatives considered**:
- *Run actual hostile Python agents in containers and observe.* Rejected as the **primary** mechanism:
  non-deterministic, network/docker-dependent (violates IV for the gate suite), and proves only the
  cases the one hostile binary happens to attempt (FR-011 forbids a pass that rests on the fixture
  merely not trying). Retained only as the **physical backstop** for sandbox-enforced facets — see D4.
- *Property-based fuzzing of the gate.* Attractive but heavier than the prototype warrants (Principle
  I). The breach-class matrix already enumerates the adversarial space; representative hostile cases
  per class are sufficient for the "v2 done" bar. Noted as a possible later increment, not in scope.

---

## D2 — What counts as proof? The by-construction vs. runtime taxonomy.

**Decision**: Classify each breach class as **by-construction** or **runtime**, and assert the right
kind of evidence for each (FR-010).

- **Runtime-prevented** (the gate evaluates a reachable attempt and denies it): classes **1** (exceed
  grants → `{:reject, :unknown_action}`), **2** (spoof recipient/method → `{:reject,
  :recipient_out_of_scope}` / `{:reject, :method_out_of_scope}`), **4** (bust the cap →
  `InferenceBroker.complete` meters and returns `{:breach, :spend}` + kill). Proof = the chokepoint
  returns the deny/breach verdict and emits its distinct loud-failure log, and `Effector.act/1` is
  never invoked for the denied action.
- **By-construction-prevented** (there is *no reachable surface* for the agent to even attempt through):
  classes **3** (exfiltrate — the only egress is `Effector.act/1`, reached only after a gate pass),
  **5** (forge a trigger — signals enter only via `TriggerGateway.submit/*`, a function API the
  sandboxed agent has no channel to), **6** (forge/self-grant approval — same intake; agent output is
  never read as an approval), **7** (read the manifest — `RunWorker.build_payload/2` puts only
  `["items","state"]` in the payload; the manifest is never serialized to the agent), **8** (hold a
  credential — `CredentialProxy.with_credential/2` runs a closure and never *returns* the secret to its
  caller). Proof = a **negative test asserting the absence of the reachable surface** (the manifest/
  credential does not appear on any agent-bound surface; an agent-originated signal/approval produces
  zero fires/zero release), which is the testable proxy for the construction.

**Rationale**: The two claims are genuinely different and the stronger (by-construction) must not be
weakened into the weaker (a runtime guard that *could* be bypassed if a surface existed). Conflating
them would let a future regression that *exposes* a surface still pass a "the guard rejected it" test.
Naming the taxonomy in the suite keeps each assertion honest about what it proves.

**Alternatives considered**: Treat everything as a runtime guard. Rejected — it understates classes
3/5/6/7/8, where the guarantee is the *unreachability* of the attack surface, not a check on a reachable
one.

---

## D3 — Where is the substrate-side evidence read from? (no agent self-report)

**Decision**: Every verdict is read from one of four substrate-owned surfaces, never from the agent
(FR-009, FR-012):

| Evidence surface | Source | Used for |
|---|---|---|
| Gate verdict | `Gate.evaluate/4` / `partition_batch/4` return value | classes 1, 2 |
| Effector invocation | injected `effector_fn` call-log (was the denied action executed?) | classes 1, 2, 3, 6 |
| Spend ledger + breach | `StateStore.snapshot("spend_ledger")`, `{:breach, :spend}` | class 4 |
| Run-log | `RunLog`-rendered lines (trigger provenance, no forged fire) | classes 5, 6 |
| Standing inventory | `Inventory.render/1` (pending approval visible; resolves once) | class 6 |
| Agent-bound payload | `RunWorker.build_payload/2` output (no manifest/credential keys) | classes 7, 8 |

**Rationale**: This is the Legibility principle (VIII) operationalized — "read without asking the
agent." `boundary_test.exs` already asserts the payload surface for the manifest (VR-001/VR-002); the
world-B suite reuses that surface and extends the same discipline to every class.

---

## D4 — Where does the docker / physical-sandbox layer sit?

**Decision**: The **deterministic world-B suite does not use docker.** The sandbox-enforced *physical*
facets — network egress disabled, read-only filesystem, hostile-web-input sanitization — are already
proven by `isolation_test.exs` under `@tag :docker`, excluded from the default run and invoked
explicitly via `mix test --include docker`. The world-B suite proves the **control-plane** facet of the
same classes by construction (no egress path but the gated effector; no manifest/credential on any
agent-bound surface) and *references* the docker tests as the physical backstop, without depending on
them for its verdict.

**Rationale**: The constitution forbids live dependencies in the assertion set (IV), and the spec
requires "no container runtime in the assertions" (FR-014). The two layers are complementary: the
control-plane layer proves *the substrate hands the agent nothing dangerous and accepts nothing
dangerous back*; the docker layer proves *the OS-level sandbox physically holds*. "v2 done" is gated on
the deterministic layer (always-on in CI); the docker layer is the periodically-run physical
confirmation.

**Alternatives considered**: Fold the docker tests into the world-B gate. Rejected — it would make the
"v2 done" signal non-hermetic and docker-dependent, and the physical facts it proves are already
captured in `isolation_test.exs`; duplicating them buys nothing.

---

## D5 — Suite shape: one consolidated suite vs. an aggregating "bar" module?

**Decision**: A **single consolidated ExUnit suite** `test/agent_os/world_b_test.exs`, one `describe`
per breach class. "The World-B bar is met" ≡ "the suite is green" (all eight classes prevented); a red
describe is the failing verification that blocks Phase 4 (SC-011). Hostile inputs live in one
agent-agnostic fixture module `test/fixtures/world_b/hostile.ex`.

**Rationale**: The suite *is* the bar — no separate aggregator process is needed to express "all eight
prevented" when a green suite already means exactly that (Principle I: the simplest thing that works).
Co-locating the eight classes in one file makes the world-B claim reviewable in one place and mirrors
the existing one-file-per-concern test layout.

**Alternatives considered**: A `WorldB` runtime module that aggregates verdicts into a report. Rejected
as over-engineering for a prototype — it adds a production module to do what a green test suite already
asserts, and risks becoming an LLM-free-but-still-spurious "second firewall" narrative. The gate is the
firewall; the suite merely verifies it.

---

## Resolved unknowns

All Technical-Context items are concrete; no `NEEDS CLARIFICATION` remains. The verification method
(D1), proof taxonomy (D2), evidence sources (D3), docker boundary (D4), and suite shape (D5) are
settled and consistent with the constitution and the existing code.
