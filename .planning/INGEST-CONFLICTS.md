## Conflict Detection Report

Mode: new
Precedence: ADR > SPEC > PRD > DOC (default; no per-doc overrides present)
Docs synthesized: 3 (1 PRD, 2 DOC)
Cross-ref graph: 3 nodes, 0 edges (all `cross_refs` empty) — acyclic, no cycles detected.

### BLOCKERS (0)

None.

- No ADRs in the ingest set, so no LOCKED decisions exist — no LOCKED-vs-LOCKED
  contradiction is possible.
- Mode is `new` with no existing `.planning` context — no ADR-vs-existing-locked
  check applies.
- No UNKNOWN / low-confidence classifications — all three docs classified with
  high or medium confidence and a definite type.
- No cross-ref cycles — the cross-ref graph has no edges.

### WARNINGS (0)

None.

- No competing acceptance variants. Requirements come from a single PRD
  (docs/agent_os.md); the plan checklist (docs/plan.md, DOC) restates the same
  capability set with identical wording and the same R1-R4 / v0-v3 sequencing,
  so there are no divergent acceptance criteria on the same scope to preserve.

### INFO (3)

[INFO] Three sources agree on roadmap scope and sequencing
  source: /Users/will/projects/agent_os/docs/agent-os-design.md (DOC)
  source: /Users/will/projects/agent_os/docs/agent_os.md (PRD)
  source: /Users/will/projects/agent_os/docs/plan.md (DOC)
  Note: The design doc's release roadmap (v0-v3), the PRD's user story map
  (R1-R4), and the plan checklist describe the same capability set with the same
  ordering (skeleton -> isolation -> enforcement -> generation). No precedence
  tiebreak was needed; nothing was dropped. plan.md is recorded as corroborating
  context, not a separate requirement source.

[INFO] v1/v2 ordering: design doc flags it as open; PRD and plan commit
  source: /Users/will/projects/agent_os/docs/agent-os-design.md (DOC)
  source: /Users/will/projects/agent_os/docs/agent_os.md (PRD)
  source: /Users/will/projects/agent_os/docs/plan.md (DOC)
  Note: The design doc presents the v1 (isolation) vs v2 (enforcement) order as
  a "genuine choice" / open question, with a risk-driven recommendation for
  isolation-first. The PRD story map and the plan both commit to isolation
  (R2/v1) before enforcement (R3/v2) — i.e. they adopt the recommended order.
  Not a conflict: the committed order is consistent with the design doc's
  recommendation, and the open-question status is preserved in
  intel/context.md (Topic: v1/v2 ordering) for downstream visibility. No
  auto-resolution by precedence was required.

[INFO] design doc carries ADR-like settled decisions but classified DOC
  source: /Users/will/projects/agent_os/docs/agent-os-design.md (DOC)
  Note: The classifier flagged that docs/agent-os-design.md reads as ADR-like
  (strong architectural reasoning, settled decisions) but lacks Accepted status,
  a numbered ADR filename, and locks many decisions plus open questions rather
  than one — so it was classified DOC, not ADR. Consequence for synthesis: its
  decisions were extracted into intel/decisions.md as `proposed`
  (settled-by-exploration), NOT `locked`. They therefore hold no lock-level
  precedence. If any of these need to win as a hard, non-overridable decision,
  promote it to a formal ADR (Accepted) before the next ingest.
