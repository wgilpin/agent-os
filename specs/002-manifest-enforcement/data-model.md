# Phase 1 Data Model: Manifest Enforcement (v2)

Entities the gate, spend meter, credential proxy, and trigger bus operate over. Elixir
entities are structs with typespecs (Principle V — no bare maps for these). Python-side
contract entities use Pydantic. Validation rules cite the FR they enforce.

## Manifest (parsed, host-side only)

The declarative source of truth for one agent. Privileged-read for the gate only; never
crosses the port boundary nor mounts into the container (FR-006).

| Field | Type | Notes |
|-------|------|-------|
| `purpose` | string | One-line contract (Phase 1, unchanged). |
| `triggers` | list of `Trigger` | `time` (existing) plus `event`, `message` (FR-014). |
| `grants` | list of `Grant` | Replaces the flat `connectors`/`outputs` lists (FR-001/002). |
| `mounts` | list of string | State mounts the agent reads (unchanged). |
| `spend` | `Spend` | `{cap, window, on_breach}` (FR-010). |
| `owner` | string | Unchanged. |
| `supervision` | string | `restart-once-and-alert` (unchanged). |

**Validation**: a manifest missing `grants` or `spend`, or with a malformed/empty constraints
sub-block, fails provisioning loudly — the agent is NOT provisioned (FR-016). Default-deny: an
action with no matching grant is rejected, never defaulted in (FR-003).

## Grant (manifest — author-controlled scope only)

The authorization for this agent to use a connector, plus the per-agent scope. The unit the gate
matches a proposed action against. Carries NO intrinsic-danger fields (those live in the
Connector Capability registry below) so a manifest author cannot downgrade a connector's danger.

| Field | Type | Rule |
|-------|------|------|
| `connector` | string | A connector name from the registry (e.g. `kv_append`, `external_send`). Generic capability, agent-agnostic; read from manifest. A proposed action's `type` must match a granted `connector` (FR-003). |
| `recipients` | list of string | Allowed recipients for this grant. A proposed recipient MUST be a member when present (FR-003). Empty/absent ⇒ recipient not applicable to this connector. |
| `methods` | list of string | Allowed methods/endpoints. A proposed method MUST be a member when present (FR-003). |

## Connector Capability (substrate registry — intrinsic, NOT author-controlled)

The substrate's source of truth for *how dangerous a capability is*. Keyed by generic connector
name. The author cannot set or change these from the manifest (D9; FR-002 scoping stays in the
manifest, danger stays in the substrate).

| Field | Type | Rule |
|-------|------|------|
| `name` | string | Generic connector name (registry key); never an agent verb (Principle IX). |
| `mutating?` | boolean | Whether the connector mutates external state. |
| `requires_approval?` | boolean | When true, every action on this connector parks pending an approval event, regardless of manifest (FR-015). |
| `credential` | atom \| nil | The capability id the `CredentialProxy` injects at the chokepoint (FR-008); `nil` for local/no-credential connectors. |
| `cost` | non-negative number | Per-action spend cost summed by the meter (FR-010a). |

## Constraints (sub-block view)

"Constraints" = the per-grant scope (`recipients`, `methods`) PLUS the connector's intrinsic
metadata (`requires_approval?`, `credential`, `cost`). The gate composes both; none are hard-coded
in gate logic — scope is read from the `Grant`, danger from the registry (FR-002, Principle IX).

## Spend

| Field | Type | Rule |
|-------|------|------|
| `cap` | non-negative number | Maximum summed cost permitted within a window (FR-010). |
| `window` | enum: `daily` (fixed) | Fixed, resetting window; spend resets to 0 at the boundary (FR-011). |
| `on_breach` | enum: `kill` | v2 supports `kill` only; a breach ends the run for real (FR-012). Schema may extend later. |

## ProposedAction (from the agent, untrusted)

Emitted by the agent across the boundary; validated, never trusted.

| Field | Type | Rule |
|-------|------|------|
| `type` | string | Must match a granted `Grant.connector` (FR-003); missing ⇒ dropped as malformed. |
| `recipient` | string \| nil | Checked against `Grant.recipients` when the grant scopes recipients. |
| `method` | string \| nil | Checked against `Grant.methods` when the grant scopes methods. |
| `payload` | map | Action-specific data (e.g. the digest text). |

## GateDecision

The deterministic outcome for one proposed action. Logged either way (FR-005).

| Variant | Meaning |
|---------|---------|
| `{:approve, grant}` | In-scope and within cap; effector may execute (credential injected if the grant's connector declares one in the registry). |
| `{:reject, reason}` | Out-of-scope. `reason` ∈ `{:unknown_action, :recipient_out_of_scope, :method_out_of_scope, :ungranted, :bad_shape}` — the specific failing constraint. |
| `{:needs_approval, grant}` | In-scope but the connector is `requires_approval?` in the registry; park as `PendingApproval` (FR-015). |
| `{:breach, :spend}` | `spent + connector.cost > cap`; trigger `on_breach` kill (FR-012). |

**Rule**: default-deny — any action not explicitly approved is rejected or breached; the effector
runs ONLY on `:approve` (FR-003, SC-001).

## SpendLedger (StateStore mount, substrate-owned)

Per-agent metered spend for the current fixed window.

| Field | Type | Rule |
|-------|------|------|
| `agent` | string | Agent identity (single agent this phase). |
| `window_start` | datetime | Start of the current fixed window; reset boundary. |
| `spent` | number | Sum of executed actions' costs in the window (FR-011). |

**Transition**: on each approved execution, `spent += connector.cost` (cost from the registry, not
the manifest). At the window boundary, `spent → 0`, `window_start → new period`. Inspectable per
agent without asking the agent (FR-011, Principle VIII).

## PendingApproval (StateStore mount, substrate-owned)

An action held awaiting an approval event (park-and-resume, FR-015).

| Field | Type | Rule |
|-------|------|------|
| `ref` | string | Correlation id matched by the approval event. |
| `action` | ProposedAction | The parked action. |
| `grant` | Grant | The grant it was validated against. |
| `parked_at` | datetime | For legibility/audit. |

**Transition**: created when the gate returns `{:needs_approval, _}`; on a matching approval
event the action is re-validated through the gate and executed; absent approval it stays pending
and the run reaches its terminal state (no blocked process — spec Edge Cases).

## Trigger

| Field | Type | Rule |
|-------|------|------|
| `type` | enum: `time` \| `event` \| `message` | `time` is the Phase 1 daily timer; `event`/`message` are in-BEAM (FR-014). |
| `at` | string | For `type: time` only (e.g. `"07:00"`). |
| `name` | string | For `type: event` — the event name (approval uses a reserved event). |

## Capability (CredentialProxy, in-memory only)

| Field | Type | Rule |
|-------|------|------|
| `credential_id` | atom | Matches a connector's `credential` field in the registry (e.g. `:outbound_token`). |
| `secret` | opaque | Held only in the proxy process; never logged, never persisted, never sent to the agent (FR-009). |

**Rule**: the secret is injected by the proxy inside the effector's execution of an approved
action and is unreachable from any LLM-running component (FR-008/FR-009, SC-004).
