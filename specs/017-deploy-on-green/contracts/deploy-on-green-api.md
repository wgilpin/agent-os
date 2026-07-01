# Deploy-on-Green Internal API Contract

This document describes the API contract and return values for the modified `AgentOS.Provisioner.deploy/3` function.

## Module: `AgentOS.Provisioner`

### Function: `deploy/3`

#### Specification

```elixir
@spec deploy(
        manifest_path :: binary(),
        review_mode :: atom() | String.t(),
        opts :: keyword()
      ) ::
        {:ok, atom()}
        | {:blocked, binary()}
        | {:error, {:gate_failed, atom()}}
        | {:error, any()}
```

#### Inputs
- `manifest_path`: Absolute path to the agent's manifest file (e.g. `"/Users/will/projects/agent_os/manifests/discovery.md"`).
- `review_mode`: Gating mode override, supporting values:
  - `"--always-review"`, `"always-review"`, `:always_review`
  - `"--review-if-risky"`, `"review-if-risky"`, `:review_if_risky`
  - `"--dangerously-skip-review"`, `"dangerously-skip-review"`, `:dangerously_skip_review`
- `opts`: Keyword list options. Can specify `:spec_dir` to override where agent code is stored, and `:spend_threshold` for envelope threshold.

#### Return Types
- `{:ok, provenance}`: The gate passed and deployment was approved automatically (either envelope skip or dangerous skip), returning the provenance atom (e.g. `:skipped_in_envelope`, `:dangerously_skipped`).
- `{:blocked, ref}`: The gate passed, but review-mode rail requires human approval. Returns a unique reference identifier string.
- `{:error, {:gate_failed, reason}}`: Deployment is blocked because the co-generated gate failed. Reason can be one of:
  - `:judge_failed`
  - `:security_review_failed`
  - `:both_failed`
  - `:missing_verdict`
  - `:stale_verdict`
- `{:error, reason}`: Other failures (e.g. manifest parsing error).
