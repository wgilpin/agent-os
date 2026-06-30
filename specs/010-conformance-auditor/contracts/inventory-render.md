# Contract: Inventory Conformance Provenance Block

`AgentOS.Inventory.render/1` gains a conformance provenance block, rendered from the **persisted**
verdict (read from `StateStore "conformance"`), placed next to the capability view / LAST RUN STATE.
The inventory does NOT recompute the verdict (FR-008/FR-012).

## Rendered shape

Clean:

```
CONFORMANCE: clean
```

Flagged (totality — every flag listed, FR-007):

```
CONFORMANCE: flagged
  [trust]  gate-breach — manifest-breach attempt recorded in last 20 runs
  [trust]  denied-approval — 3 approval-required actions denied in window
  [health] quiet — no action in 3 consecutive runs
```

Insufficient data (e.g. brand-new agent, no run history):

```
CONFORMANCE: insufficient data (N runs recorded)
```

## Rules

- Reads `StateStore.snapshot("conformance")[agent_name]`; if absent ⇒ render
  `insufficient data` rather than erroring (FR-009).
- Each flag line shows its axis (`[trust]` for `:denied_approval`/`:gate_breach`, `[health]` for
  `:quiet`/`:sick`) and the flag's human-readable description.
- The block is read-only legibility: it never implies an action, never gates anything, and is shown in
  every render (permission-visibility discipline, Principle VIII). No flag governs its display.
- Agent-agnostic: keyed by the manifest basename; no agent domain vocabulary appears in the render code.

## Test anchor

`inventory_test.exs`: given a persisted `:flagged` verdict in the `"conformance"` store, the rendered
string contains `CONFORMANCE: flagged` and a line for each flag; given no verdict, it contains
`insufficient data`; given a `:clean` verdict, it contains `CONFORMANCE: clean`.
