---
releases:
  - R1: v0 — Walking skeleton {#UmLv}
  - R2: v1 — Isolation {#7Tfz}
  - R3: v2 — Manifest enforcement {#Ctdf}
  - R4: v3 — Generation (MVP) {#kKlV}
---

# Activity: Declare an agent [declare] {#R5az}

## Step: Write a manifest [write-manifest] {#2KPW}
- [R1] [write-manifest-1] Hand-write a markdown manifest, human-kept-in-sync {#bzJO}
- [R3] [write-manifest-2] Manifest gains boundary-contract fields (recipient scoping, on_breach, approval-as-event) {#RD81}

## Step: State purpose [state-purpose] {#FITq}
- [R1] [state-purpose-1] Purpose stated as a one-line contract {#P7ju}
- [R4] [state-purpose-2] Declare a purpose; OS emits the manifest {#qhtA}

## Step: Grant connectors & mounts [grant-caps] {#kfHl}
- [R1] [grant-caps-1] Connectors & mounts listed by hand {#yelG}
- [R4] [grant-caps-2] Manifest carries a normie-readable capability render: <READ YOUR GMAIL>, <SEND EMAILS FROM YOUR GMAIL> {#ia26}
- [R4] [grant-caps-3] Render is FAITHFUL+TOTAL (every capability appears; may collapse detail, never drop one) {#UK6Y}
- [R4] [grant-caps-4] Render is DETERMINISTIC from manifest fields, never LLM-written (else co-generation misleads the consent screen) {#sYnr}
- [R4] [grant-caps-5] Render is DANGER-RANKED: read looks different from send/egress — the user sees WHY it left the envelope {#N14j}

## Step: Set spend cap [set-spend] {#5X2o}
- [R1] [set-spend-1] Spend cap as a number (no on_breach yet) {#NXrY}
- [R3] [set-spend-2] Spend becomes {cap, window, on_breach} {#Yblo}

# Activity: Provision it from the declaration [provision] {#SCTM}

## Step: Instantiate from declaration [instantiate] {#tsAh}
- [R1] [instantiate-1] Hard-wired config (not provisioned from manifest) {#R5zY}
- [R2] [instantiate-2] Provision agent into a container {#zdJv}
- [R3] [instantiate-3] Substrate provisions from the enforced manifest {#U3k9}
- [R4] [instantiate-4] OS composes/selects template, validates generated manifest is well-formed & minimally-scoped {#ocfy}

## Step: Mount state [mount-state] {#zYXh}
- [R1] [mount-state-1] Roster/trust state mounted to single-writer GenServer {#RLbN}

## Step: Wire credentials [wire-creds] {#CUeC}
- [R3] [wire-creds-1] Credential proxy holds caps, injects at request time {#kj6z}

# Activity: Trigger it into motion [trigger] {#of3B}

## Step: Wake on clock (time) [trig-time] {#uWCd}
- [R1] [trig-time-1] One timer (daily 07:00 emergence signal) {#8beo}

## Step: Wake on event (world) [trig-event] {#KjA1}
- [R3] [trig-event-1] Event-trigger + approval-as-event-trigger {#1wOw}

## Step: Wake on message / approval [trig-message] {#KEa1}
- [R3] [trig-message-1] Message-trigger (you, via chat, are another process) {#jQWl}

# Activity: Run it (LLM does the work) [run] {#S7PK}

## Step: Hand input to Python agent [hand-input] {#bvJu}
- [R1] [hand-input-1] One port → human-written Python discovery agent {#SCA3}
- [R2] [hand-input-2] Agent runs sandboxed; safe against injected bookmark/tweet {#9icU}
- [R4] [hand-input-3] OS synthesises a NOVEL agent body (new code, not template/compose) — the step the map never reached {#U9XU}

## Step: Reason over sanitized input [reason] {#lLQo}
- [R1] [reason-1] LLM reasons over input (unsanitized at v0) {#L8KL}
- [R2] [reason-2] Reasons over sanitized untrusted web input {#4Hf2}

## Step: Propose enumerated actions [propose] {#SlBh}
- [R1] [propose-1] Proposes enumerated actions {#JWKm}

# Activity: Gate its outputs before effect [gate] {#a2Nm}

## Step: Validate action vs grants [validate] {#1dB6}
- [R1] [validate-1] Minimal output check (not enforcement) {#EvrB}
- [R3] [validate-2] Deterministic gate: every action validated vs enumerated grants + constraints {#4f3m}
- [R4] [validate-3] Gate now checks a machine-written manifest (new trust posture) {#424K}
- [R4] [validate-4] Gate must hold against machine-written CODE: post-deploy safety rests on the gate, not the security LLM's reading (world B) {#i1aF}
- [R4] [validate-5] Manifest is NOT readable by the agent (privileged-read for the gate only) — agent can't hug a boundary it can't see {#Lj8X}
- [R4] [validate-6] INVARIANT: --dangerously-skip-review is deploy-review skip ONLY; the gate still enforces the manifest at runtime {#biWi}

## Step: Inject credential [inject-cred] {#lgL7}
- [R3] [inject-cred-1] Credential proxy injects at the chokepoint {#Z5MD}

## Step: Meter spend [meter-spend] {#z0ey}
- [R3] [meter-spend-1] Spend metered at the deterministic chokepoint {#Jh9U}

## Step: Act on agent's behalf [act] {#3BMV}
- [R1] [act-1] Privileged action on agent's behalf (deterministic) {#udar}

# Activity: Observe what exists & what it did [observe] {#kpJ9}

## Step: List what exists [inventory] {#KJpY}
- [R1] [inventory-1] Standing inventory of what exists {#AiqA}
- [R4] [inventory-2] Security-review verdict + judge result shown in the standing inventory (never 'ask the agent') {#yITP}
- [R4] [inventory-3] Permission summary ALWAYS shown at deploy, every mode (display, not a decision) — legibility has no flag {#5bNK}
- [R4] [inventory-4] Inventory records provenance: reviewed = human | skipped-in-envelope | dangerously-skipped {#Bpa2}

## Step: Read run-trace [run-trace] {#Y8zJ}
- [R1] [run-trace-1] A legible run-log {#hJ7t}

## Step: See spend [see-spend] {#nTGk}
- [R3] [see-spend-1] Per-agent spend visible from the chokepoint {#M1RM}

## Step: Check conformance [conformance] {#6BE0}
- [R4] [conformance-1] Conformance auditor: stated purpose vs observed behaviour, flag-only {#HsQg}
- [R4] [conformance-2] Auditor flags drift to human; human stays on approve-path {#kJkm}

# Activity: Supervise its lifecycle & failures [supervise] {#6NOQ}

## Step: Restart policy [restart] {#c93t}
- [R1] [restart-1] Restart-once-and-alert policy {#1SUB}

## Step: Kill on breach [kill-breach] {#hvGK}
- [R3] [kill-breach-1] Spend-cap-on-breach becomes a real kill {#9s3O}

## Step: Surface child crash [child-crash] {#qLnP}
- [R2] [child-crash-1] Child OOM/crash surfaces as clean BEAM exit {#nfJP}

# Activity: Generate an agent from a stated purpose [generate] {#mxb6}

## Step: Elicit the spec (question until KISS-clear) [elicit-spec] {#Krpq}
- [R4] [elicit-spec-1] Question the user until purpose is clear; minimise everything (KISS) — this is the real defence against spec-misread {#Ennb}

## Step: Write the manifest [gen-manifest] {#NXpM}
- [R4] [gen-manifest-1] Emit manifest from elicited spec; the human-readable manifest is THE safety artifact {#nxah}

## Step: Write the judge (LLM-judged eval-lite) [write-judge] {#rhj7}
- [R4] [write-judge-1] Synthesise tests; LLM-judged, non-deterministic; certifies code-matches-manifest, not manifest-matches-intent {#g7tI}

## Step: Write the novel agent [write-agent] {#dQqr}
- [R4] [write-agent-1] Synthesise novel agent body (Python/PydanticAI across the port boundary) {#tvN8}

## Step: Security review (reads code+manifest+purpose) [security-review] {#0xZH}
- [R4] [security-review-1] New agent: reads code+manifest+purpose, judges 'written to satisfy purpose without breaching manifest' — smoke detector, not firewall {#zh9b}

## Step: Deploy on green (judge AND security) [deploy-on-green] {#7jkj}
- [R4] [deploy-on-green-1] On pass from judge AND security review, deploy with no further human input — sound ONLY in world B {#w2jd}
- [R4] [deploy-on-green-2] Mode --always-review: every deploy blocks on a human (v3-LAUNCH DEFAULT; human does the SEMANTIC check, not security) {#wbru}
- [R4] [deploy-on-green-3] Mode --review-if-risky: in-envelope (read-only/no-egress/spend<threshold) auto-deploys; out-of-envelope blocks {#Kev3}
- [R4] [deploy-on-green-4] Mode --dangerously-skip-review: out-of-envelope also auto-deploys (the only genuinely dangerous mode) {#qlBT}
- [R4] [deploy-on-green-5] Envelope is a DETERMINISTIC predicate over manifest fields — never an LLM judgement {#CDuH}
- [R4] [deploy-on-green-6] OPEN: should 'conformance auditor live & watching' be a precondition of envelope-eligibility? (leaning yes) {#ns0L}
