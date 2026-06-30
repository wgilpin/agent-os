# Contract: Deploy Review Mode Rail

This contract defines the interfaces and data boundaries for the deploy-time rail.

## Module Interfaces

### 1. Provisioner Deploy Seam

Exposes the core deploy entry point.

```elixir
@type review_mode :: :always_review | :review_if_risky | :dangerously_skip_review
@type provenance :: :reviewed_human | :skipped_in_envelope | :dangerously_skipped

@spec deploy(binary(), review_mode(), keyword()) :: 
        {:ok, provenance()} 
        | {:blocked, binary()} 
        | {:error, any()}
```

### 2. Envelope Predicate

A pure, deterministic boolean evaluator over manifest fields.

```elixir
@spec envelope_predicate?(AgentOS.Manifest.t(), keyword()) :: boolean()
```

- **In-Envelope Definition**:
  - `read_only? == true` (all capability grants have `mutating? == false` or danger level `:read_only`)
  - `no_egress? == true` (all capability grants have danger level not equal to `:external`)
  - `spend_under_threshold? == true` (manifest spend cap is `<= 100,000` micro-dollars)

## Resumption Action Contract

When a deployment blocks, it registers a pending approval with the following action shape:

```elixir
%{
  type: "deploy",
  recipient: agent_name,      # Agent name (e.g. "discovery")
  method: manifest_path,      # Path to the manifest file (e.g. "manifests/discovery.md")
  payload: %{
    "review_mode" => string,  # Normalized review mode
    "hash" => string          # SHA-256 hash of the manifest file
  }
}
```

- **Resumption Handler**:
  - Resumed via `AgentOS.Effector.act/1` mapping the action type `"deploy"`.
  - The effector writes the `status: :reviewed_human` and `hash: hash` to `StateStore "provenance"`.
  - The effector triggers the agent execution via `AgentOS.RunSupervisor.start_run/1`.
