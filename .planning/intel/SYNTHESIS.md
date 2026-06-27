# Synthesis Summary

Single entry point for downstream consumers (gsd-roadmapper). Generated from the
per-doc classifications in `.planning/intel/classifications/` plus the source
documents.

Mode: new (net-new bootstrap; no existing .planning artifacts)
Precedence: ADR > SPEC > PRD > DOC (default; no per-doc overrides)

## Doc counts by type

- DOC: 2
  - /Users/will/projects/agent_os/docs/agent-os-design.md (high confidence)
  - /Users/will/projects/agent_os/docs/plan.md (medium confidence)
- PRD: 1
  - /Users/will/projects/agent_os/docs/agent_os.md (medium confidence)
- ADR: 0
- SPEC: 0
- UNKNOWN: 0

Total docs synthesized: 3

## Cross-ref / cycle status

Cross-ref graph: 3 nodes, 0 edges (all `cross_refs` empty). Acyclic. No cycles,
no traversal-depth issues. Full set synthesized.

## Decisions

- Locked: 0
- Extracted (proposed / settled-by-exploration): 18
- All from /Users/will/projects/agent_os/docs/agent-os-design.md (DOC). No ADRs
  present, so no decision is `locked`; none holds lock-level precedence.
- Detail: .planning/intel/decisions.md

## Requirements

- Extracted: 28 (one per story-map Step), spanning 9 activities
- Source: /Users/will/projects/agent_os/docs/agent_os.md (PRD)
- Release-tagged R1-R4 (v0 walking skeleton -> v1 isolation -> v2 enforcement
  -> v3 generation MVP); story-map node ids preserved
- IDs: REQ-write-manifest, REQ-state-purpose, REQ-grant-connectors-mounts,
  REQ-set-spend-cap, REQ-instantiate-from-declaration, REQ-mount-state,
  REQ-wire-credentials, REQ-trigger-time, REQ-trigger-event, REQ-trigger-message,
  REQ-hand-input, REQ-reason-over-input, REQ-propose-enumerated-actions,
  REQ-validate-action-vs-grants, REQ-inject-credential, REQ-meter-spend,
  REQ-act-on-behalf, REQ-list-inventory, REQ-read-run-trace, REQ-see-spend,
  REQ-check-conformance, REQ-restart-policy, REQ-kill-on-breach,
  REQ-surface-child-crash, REQ-elicit-spec, REQ-gen-manifest, REQ-write-judge,
  REQ-write-novel-agent, REQ-security-review, REQ-deploy-on-green
  (30 IDs; some activities share a step-group — see file)
- Detail: .planning/intel/requirements.md

## Constraints

- Extracted: 13 (no SPECs present; all from the design DOC)
- Type breakdown: schema 3, protocol 6, nfr 4 (api-contract 0)
- Detail: .planning/intel/constraints.md

## Context topics

- Topics captured: 11
  (vision/thesis, nanoclaw contrast, OS analogy, manifest frontier, conformance
  auditor framing, co-generation caveat, roadmap shape, v1/v2 ordering, open
  questions, validation owed, plan.md checklist)
- Sources: agent-os-design.md, plan.md
- Detail: .planning/intel/context.md

## Conflicts

- BLOCKERS: 0
- Competing variants (WARNINGS): 0
- Auto-resolved: 0
- INFO: 3 (roadmap-scope agreement; v1/v2 open-question vs committed order;
  design doc is ADR-like but classified DOC -> decisions are proposed not locked)
- Report: .planning/INGEST-CONFLICTS.md

## Status

READY — safe to route. No blockers, no unresolved variants. The only thing for
downstream to note: all decisions are `proposed` (no locked ADRs), and the
v1/v2 ordering is committed by the PRD/plan but flagged open by the design doc.

## Per-type intel files

- .planning/intel/decisions.md
- .planning/intel/requirements.md
- .planning/intel/constraints.md
- .planning/intel/context.md
- .planning/INGEST-CONFLICTS.md
