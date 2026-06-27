# Context

Running notes from DOC-classified sources, keyed by topic, appended verbatim
with source attribution. Sources:
- /Users/will/projects/agent_os/docs/agent-os-design.md (DOC, high)
- /Users/will/projects/agent_os/docs/plan.md (DOC, medium — roadmap checklist)

---

## Topic: Vision / thesis
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- notes: An operating system for agents. A persistent, deterministic substrate
  (the kernel) schedules, runs, isolates, resources, and supervises a population
  of invocation-scoped agents (the processes). The defining ambition — the
  thesis — is that the OS builds its own agents from a stated purpose. The
  discovery agent (surfacing high-signal AI/ML content from a people-roster) is
  the first real workload and proof case, not the product. The product is the
  OS.

## Topic: Why build it (the nanoclaw contrast)
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- notes: The motivating contrast is the "claw" class of personal-agent tools
  (nanoclaw and kin), which trade legibility for a small codebase —
  customization IS code modification, "ask the agent what's happening," state
  reconstructable but never presented, and the only window routes through the
  same non-deterministic agent you are trying to audit (circular). This OS makes
  the opposite bet: the control plane is the product. Everything an agent is and
  does is declared, enforced, observable, and killable.

## Topic: OS analogy (load-bearing)
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- notes: Kernel = substrate (scheduler, resource owner, supervisor); Process =
  invocation-scoped agent; executable header / syscall table = manifest; syscall
  boundary (user→kernel ring) = deterministic gate; timer/cron = time-trigger;
  hardware interrupt/signal = event-trigger; IPC = message-trigger; capability
  (seL4) = per-agent connector/mount grant; init/systemd/OTP supervisor = the
  supervisor; watchdog/OOM killer = spend-cap and resource kill; code review/CI
  gate = security-review agent (pre-deploy); linter/runtime assertion =
  conformance auditor (post-deploy, flag-only).

## Topic: Manifest design frontier
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- notes: The capability grant (purpose, triggers, connectors, mounts) held
  cleanly when hand-writing manifests. The boundary contract leaked in three
  places: recipient/method scoping (need a `constraints` sub-block), approval
  execution (resolved as event-trigger), and breach behaviour (spend needs
  `on_breach`). Open fork: fat manifest (scoping/approval/breach in-manifest,
  true single source of truth) vs thin manifest + separate gate-policy file.
  Leaning fat.

## Topic: Conformance auditor framing
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- notes: "Smoke detector, not sprinkler." Not a security boundary — an LLM
  judging conformance is probabilistic and can be talked around. It catches the
  semantic gap the gate is blind to (the space between "technically within
  declared capabilities" and "actually serving the stated purpose," e.g. a
  discovery agent silently biased toward three accounts by a prompt-injected
  bookmark). The trap to never fall into: if the auditor's verdict auto-gates
  deployment, you trust the system more while it is no safer. Second-order
  property: also detects drift in the human's own manifests.

## Topic: Co-generation caveat
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- notes: The judge is synthesised from the same purpose by the same system that
  writes the agent. A misread spec produces an agent AND a test-suite wrong in
  the same direction, agreeing with each other. Co-generated tests catch
  implementation slips, not spec misreads. This is why stage 1 (elicit until
  KISS-clear) is load-bearing and why the human-readable manifest — not the
  judge — is the safety artifact. The same caveat is aimed at the consent screen
  (render must be deterministic, not LLM-written).

## Topic: Roadmap shape (releases, not stories)
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- notes: v0 walking skeleton (structural milestone, BEAM substrate runs one
  hand-written agent end to end; one supervisor, one GenServer owning
  roster/trust, one timer trigger, one port to a human-written Python discovery
  agent; minimal output check; restart-once-and-alert; manifest hand-kept-in-
  sync). v1 isolation (containerise child agents; first version safe against the
  live web; usable daily). v2 manifest enforcement (gate becomes a real
  deterministic boundary; credential-proxy / capability discipline; the real bar
  is world-B airtight enforcement). v3 generation MVP (non-coder declares
  purpose, OS synthesises novel code; the defining thing; itself an entire
  roadmap, must be re-mapped as its own sequence). Value at every step: discovery
  agent works for you from v1; the OS becomes itself at v3.

## Topic: v1/v2 ordering (open choice)
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- notes: Risk-driven recommendation is isolation-first (v1) because the current
  agent processes untrusted input now, whereas enforcement primarily protects
  against a future machine author. There is a real argument for the reverse
  order if proving the architecturally-central thing first is preferred — genuine
  choice, depends which failure you'd rather not have first. NOTE: the PRD story
  map and plan.md both commit to isolation-first (R2/v1) then enforcement (R3/v2),
  consistent with the recommended order.

## Topic: Open questions carried forward
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- notes: (1) Manifest boundary-contract fork (fat vs thin) — leaning fat.
  (2) v1/v2 order — genuine choice. (3) Cross-boundary failure semantics
  (Python crash → clean BEAM exit; ports / :erlexec / equivalent).
  (4) Does the auditor share an attack surface with the agent? (two LLMs on the
  same adversarial channel). (5) v3 internal roadmap — unwritten by design.
  (6) Is the gate strong enough for world B? — hard dependency of v3, the real
  bar for "v2 done." (7) Security-review ↔ conformance-auditor shared attack
  surface. (8) Judge co-generation — does the judge need an independent
  derivation path? (9) Envelope threshold + auditor-as-precondition — leaning yes.

## Topic: Validation still owed (independent of the build)
- source: /Users/will/projects/agent_os/docs/agent-os-design.md
- notes: The manual weekend precision experiment — validating the discovery
  CONCEPT (does roster-driven surfacing actually find high-signal content) —
  remains non-optional and is separate from the v0 skeleton test. A cron'd
  Python script would validate the agent with zero OS; the BEAM substrate earns
  its v0 inclusion only because the OS is the actual project and the agent is its
  test load.

## Topic: Roadmap checklist (plan.md)
- source: /Users/will/projects/agent_os/docs/plan.md
- notes: An unchecked task checklist that restates the v0-v3 capability set in
  task form, grouped by version (v0 walking skeleton, v1 isolation, v2 manifest
  enforcement, v3 generation MVP). Content is fully consistent with the PRD story
  map (docs/agent_os.md) and the design roadmap (docs/agent-os-design.md) — it
  corroborates rather than adds new scope. Useful downstream as a ready-made task
  decomposition per release.
