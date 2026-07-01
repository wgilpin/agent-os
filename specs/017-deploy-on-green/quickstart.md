# Quickstart: Stage 6 Deploy-on-Green

This guide walks you through verifying and triggering the Stage 6 "Deploy-on-Green" gating logic.

## 1. Setup and Preconditions

Before deploying a co-generated agent, ensure that:
1. Stage 3 (LLM-as-judge) has run and recorded a verdict in `"judge_results"`.
2. Stage 5 (Security Review) has run and recorded a verdict in `"security_review_results"`.

## 2. Triggering Deployment

To attempt a deployment of the agent `discovery` using its manifest path, call:

```elixir
# In iex or Elixir code:
AgentOS.Provisioner.deploy("manifests/discovery.md", "--review-if-risky")
```

- If both the co-generated judge and security review verdicts are `:pass` and apply to the current code hash, the deployment proceeds to the review-mode rail.
- If either verdict is `:fail`, missing, or belongs to a different code version, the function returns `{:error, {:gate_failed, reason}}` and blocks the deploy.

## 3. Viewing the Standing Inventory

To inspect the status of the verdicts and any failing check details, run the standing inventory render function:

```elixir
IO.puts(AgentOS.Inventory.render())
```

It will render the status of the co-generated checks under the `DEPLOY PROVENANCE` and `JUDGE`/`SECURITY REVIEW` sections.
