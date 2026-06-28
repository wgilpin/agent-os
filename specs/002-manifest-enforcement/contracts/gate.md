# Contract: Deterministic Gate

`AgentOS.Gate` is a pure deterministic decision over a single proposed action, the parsed
manifest, and the current spend snapshot. It runs in the BEAM control plane, in front of the
effector chokepoint (FR-003/FR-004). The effector executes ONLY on `:approve` (SC-001).

## Interface

```elixir
@spec evaluate(ProposedAction.t(), Manifest.t(), Connector.registry(), SpendLedger.t()) ::
        {:approve, Grant.t()}
        | {:needs_approval, Grant.t()}
        | {:reject, reason}
        | {:breach, :spend}
      when reason: :unknown_action | :recipient_out_of_scope
                 | :method_out_of_scope | :ungranted | :bad_shape
```

The gate reads per-agent **scope** (recipients, methods) from the `Grant`, and intrinsic
**danger** (`requires_approval?`, `credential`, `cost`) from the connector registry — never from
the manifest grant (FR-002, D9). The manifest cannot downgrade a connector's danger.

A list-level helper partitions a batch of proposed actions into approved / parked / rejected /
breached, preserving order, so `run_worker` can act on approvals and park `:needs_approval`.

## Decision order (default-deny)

For each proposed action, in order — the first failing check decides:

1. **Shape** — not a map / missing `"type"` ⇒ `{:reject, :bad_shape}`.
2. **Grant match** — no granted `grant.connector == type` ⇒ `{:reject, :unknown_action}` (≡ ungranted).
3. **Recipient scope** — grant scopes `recipients` and the proposed `recipient` ∉ list ⇒
   `{:reject, :recipient_out_of_scope}`.
4. **Method scope** — grant scopes `methods` and the proposed `method` ∉ list ⇒
   `{:reject, :method_out_of_scope}`.
5. **Spend** — `ledger.spent + registry[connector].cost > spend.cap` ⇒ `{:breach, :spend}`
   (boundary: `== cap` is allowed; `> cap` breaches).
6. **Approval** — `registry[connector].requires_approval?` ⇒ `{:needs_approval, grant}`
   (park-and-resume).
7. Otherwise ⇒ `{:approve, grant}`.

## Guarantees

- **Default-deny**: anything not reaching step 7 is not executed (FR-003).
- **Scoping from manifest, danger from registry**: steps 3–4 read scope from the `Grant`; steps
  5–6 read cost/approval from the connector registry; `cap`/`window` from `Spend`. Nothing is
  hard-coded in the gate, and the manifest cannot alter a connector's intrinsic danger (FR-002,
  Principle IX, D9).
- **Loud**: every `:reject`/`:breach` is logged with the failing reason and the action type
  (FR-005); no silent denial.
- **Pure**: no side effects, no process state — deterministic given its three inputs (testable
  in isolation, the basis of the world-B unit proof, SC-008).

## Effector coupling

On `{:approve, grant}` the effector dispatches to the grant's connector; if that connector
declares a `credential` in the registry, the `CredentialProxy` injects the secret inside that
execution (FR-008). On `{:breach, :spend}` the
effector does not run, remaining actions are abandoned, and the run terminates intentionally
(no restart — FR-013). On `{:reject, _}` the effector does not run. On `{:needs_approval, _}`
the action is parked (see [triggers.md](./triggers.md)).
