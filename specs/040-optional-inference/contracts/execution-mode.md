# Contract: Execution-Mode Classification & Sidecar

**Boundary**: pipeline orchestrator ↔ generation stages (Stage 4, Stage 3), plus an
on-disk record for later inspection/re-judging.

## Classification call

`AgentOS.ExecutionMode.classify(agent_name, manifest, opts)` — invoked by the
orchestrator **after Stage 2 (manifest projection), before Stage 4 (synthesis)**.

- Inputs: manifest + purpose ONLY (same independent-derivation inputs Stage 3 and
  Stage 4 already use — co-generation isolation preserved; no elicitation
  transcript, no agent code, no judge content).
- One completion through `InferenceBroker.complete/2` under the orchestrator's
  uncapped setup token (generation remains uncapped one-off setup; no regression of
  the runtime-only cap rule).
- The question posed: *"Does fulfilling this purpose require reasoning over dynamic
  content at runtime?"* Expected model output: JSON
  `{"mode": "deterministic" | "inference", "rationale": "..."}`.
- Result is parsed into the typed `%ExecutionMode{}`. **Any** parse failure,
  broker error, or ambiguity resolves to `mode: :inference` with a logged warning —
  the safe default (wrongly-deterministic breaks purpose-fit; wrongly-inference
  only costs more).
- Tests drive this via `provider_fn` stubs exclusively (Constitution IV).

Constitution XI note: the classifier is an LLM *proposing* which of two synthesis
contracts to use — both contracts sit entirely behind the deterministic gate, and
`:deterministic` strictly narrows agent power (removes the LLM slot). The
classification confers no capability.

## Sidecar record

Path: `agents/<agent_name>/execution_mode.json` (next to `judge_spec.json` —
same precedent: pipeline-produced, per-agent, typed JSON).

```json
{"mode": "deterministic", "rationale": "fixed notification; no runtime reasoning"}
```

- Written once per generation run (Stage 4 persists it after guards pass, alongside
  the body files); regeneration overwrites.
- `ExecutionMode.load/2` on a **missing** file returns `mode: :inference` (typed,
  with a "pre-040 agent" rationale) — existing deployed agents need no migration
  and are judged/treated exactly as today.
- Readable by anyone (standing inventory, Constitution VIII); it contains no
  grants, recipients, caps, or credentials — only the one-bit contract + rationale.

## Consumers

| Consumer | Use |
|----------|-----|
| `Stage4.generate/3` | Selects the deterministic vs inference synthesis prompt; applies the mode-aware manifest-leak guard; stamps `AgentBody.execution_mode`; writes the sidecar. |
| `Stage3.generate/3` | Selects mode-matched judge-spec synthesis prompt (declared mode is an input, not a spec field). |
| `Stage3.run/3` | Evaluates against the declared mode (loads sidecar if not passed via opts). |
| Humans / inventory | "What kind of agent is this?" answered without asking the agent. |
