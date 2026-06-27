# Agent OS — Vision, Architecture, and Roadmap

*Design document. A structural plan, not a spec. Captures the decisions made during exploration so the reasoning survives the gap between sessions.*

---

## a) The vision

### What it is

An operating system for agents. A persistent, deterministic **substrate** (the kernel) that schedules, runs, isolates, resources, and supervises a population of **agents** (the processes). Agents are invocation-scoped: they wake on a trigger, run to completion as a pure function of their inputs, and die. Nothing about an agent is long-lived except its definition and the state it owns. The substrate is the only thing that persists.

The defining ambition — the thesis — is that **the OS builds its own agents from a stated purpose**. You declare what an agent is *for*; the OS provisions, constrains, runs, and supervises it. The discovery agent (surfacing high-signal AI/ML content from a people-roster) is the first real workload and the proof case, not the product. The product is the OS.

### Why build it

The motivating contrast is the "claw" class of personal-agent tools (nanoclaw and kin). They make a deliberate trade: customization *is* code modification, no config files, no control plane, "ask the agent what's happening." That trade buys a small, comprehensible codebase at the cost of **legibility**. You give an instruction, the black box whirs, and afterwards you cannot easily answer: what code was written, how much was spent, what persistent agents were set up. State is reconstructable (git history, a SQLite DB, container configs) but never *presented*, and the only offered window onto the system routes through the same non-deterministic agent you are trying to audit — circular by construction.

This OS makes the opposite bet: **the control plane is the product.** Everything an agent is and does is declared, enforced, observable, and killable. The substrate is deterministic and trusted; the agents are sandboxed and constrained; the boundary between them is an enumerated, validated contract.

### The core principles (settled)

- **Remove the LLM from the credential boundary.** No component both runs an LLM and holds a credential that can mutate external state. Privileged action happens deterministically, on the agent's behalf, after a check — the user-mode/kernel-mode ring split.
- **Agents are invocation-scoped pure functions.** They run once and die. "Looping" is not a long-lived process; it is an invocation-scoped agent plus a trigger that re-invokes it. The trigger is data, not behaviour.
- **The substrate owns all persistent state and all scheduling.** Deterministic, legible, killable.
- **No ambient authority.** An agent's manifest grants are its entire power. Nothing is implicit. (Capability-based security, in the seL4 sense.)
- **Single owner per mutable store.** Contended state is never shared; it is owned by one writer and mutated only through messages to that owner.
- **Declarative manifests as the single source of truth.** What an agent is — purpose, triggers, connectors, mounts, outputs, spend, supervision — is declared in a manifest that humans read, diffs track, and (eventually) the substrate provisions from.
- **Legibility is non-negotiable.** The system always presents a standing inventory of what exists and what it did. Never "ask the agent."

---

## b) The envisioned architecture

### The OS analogy (load-bearing, not decorative)

The design is a kernel/process split, and OS history supplies real answers rather than just vocabulary:

| OS concept | Agent OS equivalent |
|---|---|
| Kernel | The substrate: scheduler, resource owner, supervisor |
| Process | An invocation-scoped agent |
| Executable header / syscall table | The agent manifest |
| Syscall boundary (user→kernel ring) | The deterministic gate over enumerated outputs |
| Timer interrupt / cron | Time-trigger |
| Hardware interrupt / signal | Event-trigger |
| IPC / syscall from another process | Message-trigger (you, via chat, are another process) |
| Capability (seL4) | Per-agent connector/mount grant, checked by the credential proxy |
| init / systemd / OTP supervisor | The supervisor + per-agent failure policy |
| Watchdog timer / OOM killer | Spend-cap and resource kill (see below) |
| Code review / CI gate before merge | The security-review agent (pre-deploy, on synthesised code) |
| Linter / runtime assertion (warns, can't block) | The conformance auditor (post-deploy, on run-traces, flag-only) |

**Scheduling model: run-to-completion with kill-based preemption.** Agents are not paused and resumed mid-reasoning — snapshotting an LLM's context window is expensive and lossy, so cooperative run-to-completion is correct. But non-preemptive scheduling has the classic failure mode: one process that never yields hangs the system. The answer is not classic preemption (pause/resume) but **termination**: the substrate cannot interrupt-to-timeshare, but it *must* be able to interrupt-to-kill when an agent exceeds its budget. The spend-cap-on-breach is this killer. (A BEAM substrate gets preemptive-by-reduction-counting for free at the VM floor, which dissolves the hang risk for the orchestration layer; the kill is still needed for the agent's own resource budget.)

### The trigger taxonomy (complete)

Three ways to wake a process, therefore three trigger types: **time** (the clock), **event** (the world), **message** (another process, including you). The taxonomy held against every real agent without a fourth type appearing — complete for the same reason the OS one is. Approval, notably, is modelled as an **event** ("on approval-granted, fire executor"), which keeps everything invocation-scoped and avoids smuggling long-lived state back in.

### The agent manifest

Seven core fields, each rendering directly as an inventory column: **purpose, trigger(s), connectors (+scope), mounts, outputs, spend, owner/supervision.**

**Purpose is a contract, not a label.** It is the one-sentence statement of what the agent is allowed to be for, readable as the top inventory line *and* checkable against the capability set below it. If an agent's purpose says "read and digest" but its outputs include "send email," the purpose and the capabilities visibly disagree. Purpose is the top of the same spine the capability fields sit on.

**The manifest is two schemas wearing one hat** (surfaced by hand-writing manifests for the discovery and operational agents):

1. **The capability grant** — purpose, triggers, connectors, mounts. Describes the agent *in isolation*. This held cleanly.
2. **The boundary contract** — what the substrate guarantees in response. This is where the hand-written manifests leaked, in three places:
   - **Recipient/method scoping.** `scope: read` is too coarse. "May use the gmail credential, but only to send to allowlisted addresses" must live *in the manifest*, or the real policy hides in the gate and legibility is lost. Connectors need a `constraints` sub-block.
   - **Approval execution.** `requires_approval: true` implies a pending store, a notification path, and a second deterministic step that actions approved items — none of which the agent-side schema models. Resolved by treating approval as an event-trigger.
   - **Breach behaviour.** A spend cap is meaningless without `on_breach` (abort? skip next invocation? alert?). A cost control that fails silent is worse than none. Spend is `{cap, window, on_breach}`, not two numbers.

The frontier of the manifest design is the boundary contract, not the capability grant. The open fork: push scoping/approval/breach *into* the manifest (heavier schema, true single source of truth) vs. a thin manifest plus a separate gate-policy file (lighter, two places to look). Leaning toward the former.

### The three-part enforcement spine

```
manifest  →  deterministic provisioner  →  agent run (LLM)  →  deterministic gate  →  effect
(source of    (instantiates from           (reasons over        (validates every       (privileged
 truth)        declaration)                 sanitized input,     action against the      action,
                                            proposes only        manifest's enumerated   on the
                                            enumerated actions)  grants + constraints)   agent's behalf)
```

The credential proxy sits at the gate, holds the capabilities, injects credentials at request time, and is the natural chokepoint for **per-agent spend metering** — which falls out for free as a side effect of doing auth properly through a deterministic chokepoint. (This is a structural advantage over the claw model, which has no such chokepoint for spend and cannot easily retrofit one.)

### The conformance auditor (a review layer, *not* a firewall)

An independent agent that checks whether a built agent *does its purpose and nothing but*. Critical framing, because "fuzzy agentic firewall" hides a trap:

- **It is not a security boundary.** An LLM judging conformance is probabilistic and can be talked around; putting it on the safety-critical path reintroduces the exact non-determinism the architecture removes. The deterministic gate is the firewall. The auditor is a **smoke detector, not a sprinkler.**
- **It catches the semantic gap the gate is blind to** — the space between "technically within declared capabilities" and "actually serving the stated purpose" (e.g. a discovery agent silently biased toward three accounts by a prompt-injected bookmark; every action legal, the purpose contract violated).
- **Three disciplines make it real:** (1) it audits *behaviour from real run-traces*, not self-description; (2) its authority is **asymmetric** — it can raise a flag to the human, it can *never* grant a pass (a false-positive costs attention, a false-negative-blessing costs safety); (3) its question is **bounded** to "given the agent may do X, Y, Z, is what it *did* consistent with the purpose?", not open-ended "is anything wrong here," which is proving-a-negative and where these auditors quietly underperform while looking like they work.
- **The trap to never fall into:** if the auditor's verdict auto-gates deployment ("auditor says fine → goes live"), the value inverts — you trust the system *more* while it is no safer. A human stays on the approve path for anything the gate cannot deterministically enforce.
- **A nice second-order property:** comparing stated purpose against observed behaviour also detects drift in the *human's own manifests* — it keeps the single source of truth honest.

### The synthesis pipeline (v3 — how the OS authors an agent)

The thesis move: a **non-coder** declares a purpose in conversation, and the OS synthesises a **novel** agent — actual new code, not a parameterised template and not a composition of pre-vetted components. Those weaker readings were rejected because both presuppose a coder upstream (someone wrote the template, someone curated the components); novel synthesis is the only one that delivers the non-coder promise. The price of novel synthesis is that the *executable itself* is now machine-authored and unreviewed by a human — and the entire safety argument is that **the manifest, the isolation, and the deterministic gate make that tolerable**, because none of them care who wrote the code. They constrain what the code can *do*, not what it *says*.

The pipeline is six deterministic-ish stages, human-out-of-the-loop after the conversation:

1. **Elicit the spec.** Question the user until the purpose is clear, aiming to *minimise everything* (KISS). This is the real defence against spec-misread — the human-readable manifest that results is the actual safety artifact, so the conversation is where correctness is won or lost.
2. **Write the manifest.** Emit the declaration (purpose + capability grant + boundary contract) from the elicited spec.
3. **Write the judge.** Synthesise tests for the agent. For an LLM-based agent these are non-deterministic and LLM-judged — an eval-lite, not a full eval. Honest scoping: the judge certifies "the code does what the manifest says," **not** "the manifest is what the user meant" (see the co-generation caveat below).
4. **Write the agent.** Synthesise the novel agent body (Python/PydanticAI across the port boundary).
5. **Security review.** A new agent (see below) reads manifest + purpose + agent code and judges whether the code *appears written to satisfy the purpose without breaching the manifest*.
6. **Deploy on green.** On a pass from **both** judge and security review, deploy. Whether deploy *also* blocks on a human decision is governed by the review mode (see *Review modes and permission visibility* below) — it is not unconditionally human-out-of-the-loop.

**Two commitments make stage 6's no-human auto-deploy sound** (drop either and the pipeline quietly becomes unsafe):

- **World B, not world A.** Post-deploy safety must rest on the **deterministic gate physically preventing** a manifest breach regardless of what the agent's code does — *not* on the security LLM having read the code correctly. Under world B, a security-review false-negative ships a junk agent, not a breach, because the gate blocks the offending action at runtime anyway. Under world A (trusting the LLM's reading) a false-negative ships a breach. Auto-deploy-on-green is defensible **only** in world B. This is the same "smoke detector, not sprinkler" discipline as the conformance auditor: the security review is a code-reading smoke detector; the gate is the firewall.
- **The manifest is not readable by the agent.** Stronger than read-only. The *gate* reads and enforces the manifest from outside the agent; the agent is the untrusted party it is enforced *against*. An agent that can read its own allowlist knows exactly where the walls are and can hug the boundary precisely — maximally bad while staying legal. An agent that cannot see its manifest must guess. So: manifest is **privileged-read for the gate, not visible to the agent at all** (read-only-if-exposed is the fallback, not-exposed is the default). This slots into the existing trust-zone split as a zone the agent can neither write *nor read*.

**Co-generation caveat (the one to watch):** the judge is synthesised from the same purpose by the same system that writes the agent. A misread spec produces an agent *and* a test-suite wrong in the same direction, agreeing with each other. Co-generated tests catch implementation slips, not spec misreads. This is *why* stage 1 (elicit until KISS-clear) is load-bearing rather than decorative, and why the human-readable manifest — not the judge — is the safety artifact.

### The security-review agent (distinct from the conformance auditor)

They rhyme — both ask "does this serve its purpose and nothing but" — but they are **two different components** on every axis, and conflating them loses the point:

| | Security-review agent | Conformance auditor |
|---|---|---|
| Reads | **Code** (the synthesised agent body) | **Run-traces** (what it actually did) |
| When | **Pre-deploy**, once | **Post-deploy**, continuously |
| Question | "Is this code written to satisfy the purpose without breaching the manifest?" | "Is what it *did* consistent with the purpose?" |
| Authority | Gate-on-green at deploy (sound only in world B) | **Flag-only**, never blesses |

Both are LLMs and therefore probabilistic; neither is the firewall. The deterministic gate remains the only safety boundary. The security-review agent is new at v3 and arrives *with* generation (it has nothing to review until the OS writes code); the conformance auditor also becomes load-bearing at v3 but is conceptually separable — it audits any running agent, hand-written or synthesised.

### Review modes and permission visibility (two orthogonal axes)

Whether a synthesised agent's deploy waits for a human is a *policy*, not a fixed step. It decomposes into two axes that must not be collapsed — one governs **whether deploy blocks on a human**, the other governs **whether the human can see what they're consenting to**. The first has a flag; the second never does.

**Axis 1 — review mode (governs blocking on a human decision).** Three modes, on a single monotonic axis where each mode's skip-set strictly contains the previous one's:

- **`--always-review`** — every deploy blocks on a human, in-envelope or not. The correct **default at v3 launch**, precisely because world B is *unproven* until the gate has earned it; loosen only once the gate's airtight-enforcement property is demonstrated, not assumed. In this mode the human's job is the **semantic** check (is this agent what I *meant*; does the purpose match my intent) — the same question the conformance auditor asks, moved before deploy instead of after. It is *not* a security check; the gate does that regardless.
- **`--review-if-risky`** (the eventual default) — the **capability-scoped envelope**. In-envelope agents (read-only, no egress, spend under threshold) deploy without blocking; out-of-envelope agents (any write/send/egress grant) block on a human. Spends human attention only where it changes outcomes — a non-coder reviewing every deploy rubber-stamps by Thursday, so we reserve the blocking review for grants that can actually mutate the world. **The envelope is a deterministic predicate over manifest fields, never an LLM judgement** (an LLM deciding "is this skippable" would reintroduce the non-determinism the architecture removes).
- **`--dangerously-skip-review`** — even out-of-envelope agents deploy without blocking. The only *genuinely* dangerous mode (in the middle mode "skip" only ever applied to agents that were safe-to-skip anyway). Named to be felt.

**All three modes sit *above* the gate. None of them is permission to cross it.** `--dangerously-skip-review` is **deploy-review skip only** — it skips the human eyeballing a deploy, and does **not** touch the gate. Even in the most dangerous mode the deterministic gate still enforces the manifest at runtime: skip-review means "deploy this email-sender without a human approving it first," never "let this agent exceed its manifest." If skip-review ever bled into gate-bypass, you would be back in world A with no floor at all. This is an invariant, not a setting.

**Axis 2 — permission visibility (always on, no flag, no exception).** Independent of mode, the agent's capability grant is **always shown** at deploy, rendered in normie-readable form. This is *display, not a decision*: the three modes decide whether the shown summary requires a click or merely scrolls into the inventory, but the summary is never suppressed. Without this, `--review-if-risky` has a silent failure — an in-envelope agent auto-deploys and the user never learns it was granted `<READ YOUR GMAIL>`, because "read-only was safe to skip" quietly became "permission grant was invisible." That is exactly the nanoclaw black-box failure this project exists to escape, rebuilt inside our own safe mode. So: you may be reckless about *approving* (that's what the dangerous flag buys), but the system is **never** allowed to be silent about *what it granted*. Legibility is the one principle with no flag.

Worked example: *"Write me something to reply to emails from recruiters"* → the OS surfaces **"I'll need `<READ YOUR GMAIL>` and `<SEND EMAILS FROM YOUR GMAIL>`."** The send grant is what kicks this agent out of the `--review-if-risky` envelope; the readable view is *where the user sees why* this one stopped for review and the read-only discovery agent didn't.

**The normie-readable render has three hard requirements** (it is the actual consent interface between the manifest and a non-coder, so it carries real weight):

- **Faithful and total, not a summary.** Every capability in the manifest must appear in the readable view. It may *collapse detail* ("send to 3 allowlisted addresses" rather than listing them) but may never *drop a capability*. If the readable version ever says less than the manifest grants, the user consents to less than they get and the readable layer becomes a lie.
- **Deterministically rendered from the manifest, never LLM-written.** A lookup from capability-type to phrase, computed mechanically from manifest fields — *not* prose authored by the model that wrote the manifest. If the same model authors both the grant and its description, a misread produces a manifest and a description that agree with each other and both mislead; the co-generation caveat, now aimed at the consent screen. The render must be unable to drift from what is actually granted.
- **Danger-ranked in the phrasing.** `<READ YOUR GMAIL>` and `<SEND EMAILS FROM YOUR GMAIL>` must not look alike — the egress/send capability is the one that ejects the agent from the auto-deploy envelope, and the user should *see why*. The same read-only/no-egress distinction that **defines** the deterministic envelope is the one the readable layer **surfaces** to the human: the machine uses it to decide whether to block, the human reads it as the reason. One concept, rendered twice — the manifest genuinely being the single source of truth.

The two axes are orthogonal: **mode** is *blocking on approval* (flagged, three points, monotonic, above the gate); **visibility** is *showing the grant* (unflagged, always on, deterministic render). Collapsing them is the latent bug — it is what lets a "safe" mode become a silent one.

### State and concurrency

Parallelising agents (don't-wait scheduling) immediately raises shared mutable state. The resolution is the one the 1970s actually converged on — not better locks, but *stop sharing memory; pass messages* (CSP/Actors). Different stores have different concurrency profiles and get different treatment:

- **Append-only legible logs (e.g. the digest log): git-backed markdown.** Git gives a totally-ordered, reason-over-able history and optimistic concurrency that surfaces conflicts loudly instead of corrupting silently. *Caveat:* git protects bytes, not meaning — it will cleanly auto-merge two agents asserting contradictory facts. Necessary and good for the record; not a concurrency *solution* for semantic state.
- **Contended structured state (the roster / trust-propagation KG): single-writer process.** A KG does not git-merge meaningfully, and the trust engine has mutable, contended, numerically-sensitive state (lost-update is a real corruption risk). One process owns it; everyone else messages it; mutation is serialized by construction; no locks because no sharing. (nanoclaw reached the same "one writer per store" answer from the other direction.)

### Runtime substrate: BEAM/OTP (with eyes open)

BEAM is the only widely-used runtime built around exactly this model: cheap isolated processes, no shared memory, message-passing, supervision trees with let-it-crash, per-process heaps that die with the process, preemptive-by-reduction scheduling, near-free distribution. The supervisor and watchdog questions *vanish into the runtime* rather than being bolted on.

**The seam:** the heavy work (LLM agent runs, Python/PydanticAI on Vertex/Anthropic) is *not* in BEAM. BEAM is the **control plane** — supervisors, schedulers, mailboxes, state-owners (the KG behind a GenServer is single-writer for free) — and agent invocation is a port/HTTP boundary out to a Python runtime or container. This is the correct division (BEAM does what it is best at; Python does the ML work it would be mad to do in Erlang), but the failure semantics must cross that boundary cleanly: a Python agent OOMing in a container must surface to its BEAM supervisor as a clean process exit so let-it-crash works.

Background note: prior Elixir experience exists, and Gleam (strong typing) is appealing — deferred, not rejected. The gate, manifest schema, and capability tokens *want* ill-formed-states-unrepresentable, which is where Gleam's typing would pay for itself. Sequencing: Elixir now (most reps, OTP is what's needed); revisit Gleam when building the gate, by which point there is a running system to bolt it onto rather than a green field to get lost in. Elixir's improving set-theoretic types may close enough of the gap to make a switch unnecessary.

---

## c) The roadmap (releases, not stories)

**v0 is a structural milestone — a walking skeleton — not an MVP.** It traverses the whole backbone (spawn → run → own state → supervise) for *one hand-written agent*, proving the spine is real. It is explicitly *not viable* for the OS's defining purpose, because that purpose requires isolation, enforcement, and generation, all of which are deferred. The MVP is v3.

The single ordering constraint that **cannot** be reshuffled: **enforcement must precede generation.** The moment the *author* of an agent is the machine rather than a reviewed human, human-review-as-gate evaporates, and a generated agent with no enforced manifest is precisely the black box this project exists to escape. Enforcement earns trust on easy mode (human authors) before generation makes it load-bearing on hard mode.

### v0 — Walking skeleton *(structural milestone, not a release candidate)*

The BEAM substrate runs one hand-written agent end to end.

- One supervisor; one GenServer owning the roster/trust state (single-writer); one timer trigger (the daily 07:00 emergence signal); one port boundary to a **human-written (Claude-assisted) Python discovery agent**.
- A minimal output check (not yet a hardened enforcer) and a restart-once-and-alert policy.
- Manifest is a hand-written markdown doc, kept in agreement with the runtime config *by the human* — the substrate does not yet provision from arbitrary manifests.
- A legible run-log.
- **Absent by design:** orchestrator, agent-generator, synthesis pipeline, security-review agent, conformance auditor, general manifest interpreter, isolation, real enforcement.

The weekend test for v0 is *not* "does the agent surface good content" (that is the separate manual-precision concept experiment) — it is **"does the one-supervisor / one-store / one-port skeleton feel right, or does it fight me?"** That skeleton is the abstraction everything hangs off; feel its shape against one real agent before the second agent and the generator arrive.

### v1 — Isolation

Containerise the child agent(s). The discovery agent reads X — untrusted input, a bookmarked tweet can carry an injection — so this is the first version **safe to leave running against the live web.** Usable-by-you-daily, even though the agent is still hand-written. *Risk-driven recommendation: isolation before enforcement, because the current agent processes untrusted input now, whereas enforcement primarily protects against a future machine author.* (There is a real argument for the reverse order if proving the architecturally-central thing first is preferred — open choice.)

### v2 — Manifest enforcement

The gate becomes a real deterministic boundary: every agent action validated against the manifest's enumerated grants and constraints, with the credential-proxy / capability discipline behind it. Still hand-written agents, but the manifest is now *enforced*, not merely *honoured*. This is the version ready to have a generator pointed at it. Likely also where the boundary-contract manifest fields (recipient scoping, approval-as-event, breach behaviour) get built for real, and a candidate point to introduce Gleam for the gate.

### v3 — Agent generation from purpose *(the MVP — and itself an entire roadmap)*

The orchestrator. The thesis: a **non-coder** declares a purpose, the OS synthesises **novel code** for the agent and provisions it. This is the first version that does the defining thing the OS was for, and it is safe *because* v2's enforcement is real and proven, legible *because* v1's isolation contains it and the manifest describes it. The full reasoning is in *The synthesis pipeline* and *The security-review agent* above; the roadmap entry only sequences it.

**This is not atomic.** Its internal backbone is the six-stage pipeline — elicit spec (KISS) → write manifest → write judge → write agent → security-review → deploy-on-green — human-out-of-the-loop after the conversation. Its red-team surface is larger than a hand-written agent's on two fronts: the gate now checks a *machine-written manifest*, and the runtime now runs *machine-written code*. Two new LLM components arrive here, both probabilistic, neither a firewall: the **security-review agent** (reads code pre-deploy) and the **conformance auditor** (reads traces post-deploy). They are distinct components (see table above), and they arrive together with generation because that is the trust-shift they both exist to absorb.

**The two commitments that make no-human auto-deploy sound** (restated here because they are acceptance criteria, not nice-to-haves): post-deploy safety rests on the **deterministic gate**, not on the security LLM's reading (world B); and the **manifest is not readable by the synthesised agent**. If either fails, v3 has quietly put an LLM on the safety-critical path — the exact inversion the architecture exists to avoid. Note that "no-human auto-deploy" is itself mode-gated (see *Review modes and permission visibility*): the v3-launch default is `--always-review`, loosening to `--review-if-risky` only once the gate's world-B property is demonstrated. Permission visibility is on in every mode; only the *blocking* is relaxed.

**Re-map this as its own release sequence when it is next; do not treat it as one release**, or scope-gravity relocates here and v3 becomes the release that never finishes. The headline acceptance criterion is the trust posture of running machine-written code behind a gate strong enough to make that code's intentions irrelevant.

### Value at every step

v1 gives a daily-runnable discovery agent in a box; v2 gives a trustworthy enforcement layer to reason about; v3 gives the generator. The discovery agent *works for you* from v1; the OS *becomes itself* at v3. Story-mapping's promise — value at every release, not all of it deferred to the end — actually pays off.

---

## Open questions carried forward

- **Manifest boundary-contract fork:** fat manifest (scoping/approval/breach in-manifest, true single source of truth) vs. thin manifest + separate gate-policy file. Leaning fat.
- **v1/v2 order:** isolation-first (risk-driven, recommended) vs. enforcement-first (architecturally-central-first). Genuine choice, depends which failure you'd rather not have first.
- **Cross-boundary failure semantics:** exact mechanism by which a Python-agent crash/OOM/kill in a container surfaces to its BEAM supervisor as a clean exit (ports / `:erlexec` / equivalent).
- **Does the auditor share an attack surface with the agent?** Two LLMs on the same adversarial input channel (e.g. a bookmarked tweet) can share an injection vector. Mitigated by a narrow, capability-stripped, flag-only auditor, but not fully escapable — worth explicit design.
- **v3 internal roadmap:** unwritten by design. The headline acceptance criterion is the trust posture of running *machine-written code* behind a gate strong enough to make that code's intentions irrelevant (world B). Settled this pass: novel synthesis (not template/compose); six-stage pipeline; security-review and conformance-auditor are distinct components; manifest not agent-readable.
- **Is the gate actually strong enough for world B?** Auto-deploy-on-green is sound *only* if the deterministic gate genuinely prevents any manifest breach regardless of agent code. This is now a hard dependency of v3, not a v2 nice-to-have — v2's enforcement has to be airtight *before* it carries machine-written code, not just hand-written. The real bar for "v2 done."
- **Security-review ↔ conformance-auditor shared attack surface.** Both are LLMs; the security agent reads adversarial machine-written *code*, the auditor reads adversarial *traces*. Two probabilistic reviewers on machine-generated artifacts — do they share an injection/evasion vector (e.g. code written to fool a reviewer it knows is an LLM)? Worth explicit design; mitigated but not escaped by world B (gate catches the *action* even if both reviewers are fooled).
- **Judge co-generation.** Judge and agent are synthesised from the same purpose by the same system, so they agree on a misread spec. Tests catch implementation slips, not spec misreads. Mitigation is stage-1 elicitation quality; is that enough, or does the judge need an independent derivation path?
- **Envelope threshold + auditor-as-precondition.** The `--review-if-risky` envelope is read-only / no-egress / spend-under-threshold — but *what threshold*, and should "the conformance auditor is live and watching this agent" be a **precondition** of envelope-eligibility? Leaning yes: if a skipped agent gets neither human review up front nor auditor watching after, nothing ever catches a misunderstood-but-legal agent. Ties the two v3 components together — skip the human up front *because* the auditor backstops after. Cost: the auditor must exist and be reliable before the looser mode is usable.

## Validation still owed (independent of the build)

- The **manual weekend precision experiment** — validating the discovery *concept* (does roster-driven surfacing actually find high-signal content) — remains non-optional and is separate from the v0 skeleton test. Concept validation and skeleton validation are different experiments; don't let one masquerade as the other.
- A cron'd Python script would validate the *agent* with zero OS. The BEAM substrate earns its v0 inclusion only because the OS is the actual project and the agent is its test load — a deliberate choice, not the story-mapping-purist's v0 (which would be the cron).