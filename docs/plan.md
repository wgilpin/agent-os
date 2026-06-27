# v0 — Walking skeleton

[] Hand-write a markdown manifest, human-kept-in-sync
[] Purpose stated as a one-line contract
[] Connectors & mounts listed by hand
[] Spend cap as a number (no on_breach yet)
[] Hard-wired config (not provisioned from manifest)
[] Roster/trust state mounted to single-writer GenServer
[] One timer (daily 07:00 emergence signal)
[] One port → human-written Python discovery agent
[] LLM reasons over input (unsanitized at v0)
[] Proposes enumerated actions
[] Minimal output check (not enforcement)
[] Privileged action on agent's behalf (deterministic)
[] Standing inventory of what exists
[] A legible run-log
[] Restart-once-and-alert policy

# v1 — Isolation

[] Provision agent into a container
[] Agent runs sandboxed; safe against injected bookmark/tweet
[] Reasons over sanitized untrusted web input
[] Child OOM/crash surfaces as clean BEAM exit

# v2 — Manifest enforcement

[] Manifest gains boundary-contract fields (recipient scoping, on_breach, approval-as-event)
[] Spend becomes {cap, window, on_breach}
[] Substrate provisions from the enforced manifest
[] Credential proxy holds caps, injects at request time
[] Event-trigger + approval-as-event-trigger
[] Message-trigger (you, via chat, are another process)
[] Deterministic gate: every action validated vs enumerated grants + constraints
[] Credential proxy injects at the chokepoint
[] Spend metered at the deterministic chokepoint
[] Per-agent spend visible from the chokepoint
[] Spend-cap-on-breach becomes a real kill

# v3 — Generation (MVP)

[] Declare a purpose; OS emits the manifest
[] Manifest carries a normie-readable capability render: <READ YOUR GMAIL>, <SEND EMAILS FROM YOUR GMAIL>
[] Render is FAITHFUL+TOTAL (every capability appears; may collapse detail, never drop one)
[] Render is DETERMINISTIC from manifest fields, never LLM-written (else co-generation misleads the consent screen)
[] Render is DANGER-RANKED: read looks different from send/egress — the user sees WHY it left the envelope
[] OS composes/selects template, validates generated manifest is well-formed & minimally-scoped
[] OS synthesises a NOVEL agent body (new code, not template/compose) — the step the map never reached
[] Gate now checks a machine-written manifest (new trust posture)
[] Gate must hold against machine-written CODE: post-deploy safety rests on the gate, not the security LLM's reading (world B)
[] Manifest is NOT readable by the agent (privileged-read for the gate only) — agent can't hug a boundary it can't see
[] INVARIANT: --dangerously-skip-review is deploy-review skip ONLY; the gate still enforces the manifest at runtime
[] Security-review verdict + judge result shown in the standing inventory (never 'ask the agent')
[] Permission summary ALWAYS shown at deploy, every mode (display, not a decision) — legibility has no flag
[] Inventory records provenance: reviewed = human | skipped-in-envelope | dangerously-skipped
[] Conformance auditor: stated purpose vs observed behaviour, flag-only
[] Auditor flags drift to human; human stays on approve-path
[] Question the user until purpose is clear; minimise everything (KISS) — this is the real defence against spec-misread
[] Emit manifest from elicited spec; the human-readable manifest is THE safety artifact
[] Synthesise tests; LLM-judged, non-deterministic; certifies code-matches-manifest, not manifest-matches-intent
[] Synthesise novel agent body (Python/PydanticAI across the port boundary)
[] New agent: reads code+manifest+purpose, judges 'written to satisfy purpose without breaching manifest' — smoke detector, not firewall
[] On pass from judge AND security review, deploy with no further human input — sound ONLY in world B
[] Mode --always-review: every deploy blocks on a human (v3-LAUNCH DEFAULT; human does the SEMANTIC check, not security)
[] Mode --review-if-risky: in-envelope (read-only/no-egress/spend<threshold) auto-deploys; out-of-envelope blocks
[] Mode --dangerously-skip-review: out-of-envelope also auto-deploys (the only genuinely dangerous mode)
[] Envelope is a DETERMINISTIC predicate over manifest fields — never an LLM judgement
[] OPEN: should 'conformance auditor live & watching' be a precondition of envelope-eligibility? (leaning yes)
