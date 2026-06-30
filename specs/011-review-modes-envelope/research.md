# Research: Review Modes and Deterministic Envelope Predicate

## Technical Choices and Rationales

### 1. Envelope Predicate Evaluation Logic

- **Decision**: Evaluate read-only and no-egress status using the entries processed by `AgentOS.CapabilityRender.entries/1`.
- **Rationale**:
  - `CapabilityRender.entries/1` already maps manifest grants to capability registry entries and categorizes danger levels (`:read_only`, `:local`, `:external`).
  - Read-only matches `entry.danger == :read_only` (which corresponds to `mutating? == false`).
  - No-egress matches `entry.danger != :external` (which allows `:read_only` and `:local` capabilities but forbids `:external` ones).
  - Reusing this logic ensures complete alignment between the capability render shown at deploy time and the envelope predicate, eliminating any risk of drift.
- **Alternatives Considered**: Recalculating the danger tier or duplicating the checks in `AgentOS.Provisioner`. Rejected because duplication increases the footprint and maintenance overhead.

### 2. Spend Threshold Evaluation

- **Decision**: Bound the maximum allowed spend cap to `100,000` micro-dollars (inclusive).
- **Rationale**: Verified and selected by the user during the clarification phase (Option B). This represents a limit of $0.10 USD.
- **Alternatives Considered**: Lower bounds (Option A: 10,000 micro-dollars) or higher bounds (Option C: 1,000,000 micro-dollars).

### 3. Conformance Flag Precondition Check

- **Decision**: Retrieve the conformance verdict for the agent from the `"conformance"` store and inspect it for tripwire `:gate_breach` flags.
- **Rationale**:
  - Verified and selected by the user during the clarification phase (Option B).
  - Only `:gate_breach` (tripwire severity) conformance flags make the agent ineligible for auto-deploy under `--review-if-risky`.
  - Other flags (health: `:quiet`, `:sick`) are ignored by the deploy-time rail since they do not constitute active security violations.
- **Alternatives Considered**:
  - Blocking on any conformance flag (Option A). Rejected by the user.
  - Ignoring conformance flags completely (Option C). Rejected by the user.

### 4. Human-Block Resumption and Parking

- **Decision**:
  - When a block is required, generate a unique approval ref (`ref_deploy_...`) and store a deploy action in the `"pending_approvals"` state store.
  - Implement a match for `"deploy"` type actions in `AgentOS.Effector.act/1`.
  - Upon approval, the effector records the provenance as `reviewed=human` in the `"provenance"` store and calls `AgentOS.RunSupervisor.start_run/1` to resume the agent run.
- **Rationale**: Fully integrates with the Spec 007 approval-as-event-trigger pipeline, reusing the existing `TriggerGateway` approval intake and `Effector` execution path with minimal additional code.
- **Alternatives Considered**: Creating a parallel deploy-approval state machine. Rejected because it would duplicate GenServer and registration logic unnecessarily.

### 5. Provenance Storage and Execution Re-runs

- **Decision**:
  - Create a new StateStore named `"provenance"` that persists agent deployment states to `data/provenance.term`.
  - Map each agent's name to a map containing `%{status: provenance_status, hash: manifest_hash}`.
  - When starting a run, the deploy rail checks if the current manifest's hash matches the recorded hash in the `"provenance"` store. If it matches, the run proceeds instantly, preventing infinite approval loops on `--always-review`. If the hash differs, the review logic is executed again.
- **Rationale**: Provides a clean, persistent registry of approved deploys, guarantees that any modification to the manifest file triggers a new review check, and solves the infinite loop problem deterministically.
- **Alternatives Considered**: Storing provenance inside the `"conformance"` store. Rejected because deployment provenance is a deploy-time control plane concern rather than a runtime conformance auditing concern.
