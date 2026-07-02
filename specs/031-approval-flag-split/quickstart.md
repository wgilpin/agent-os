# Quickstart: Approval Flag Split

This guide explains how to verify the split build-time and runtime approval flag behaviors.

## 1. Verifying Split Flag Behavior

To verify that a connector blocks at deploy time but runs freely at runtime:

1. Configure a connector with `requires_deploy_consent?: true` and `requires_runtime_approval?: false`.
2. Deploy an agent with this grant:
```elixir
# Deployment blocks and returns a block ref
{:blocked, ref} = AgentOS.Provisioner.deploy("manifests/my_agent.md", :review_if_risky)
```
3. Approve the deployment via the LiveView screen or by submitting the approval trigger:
```elixir
AgentOS.TriggerGateway.submit_sync({:approval, :approve, ref})
```
4. Run the agent. When the agent proposes an action of this connector type, verify the Gate approves it immediately:
```elixir
# Returns {:approve, grant} rather than {:needs_approval, grant}
{:approve, grant} = AgentOS.Gate.evaluate(proposed_action, manifest, registry, spend)
```

## 2. Running Verification Tests

To verify that the entire codebase is free of legacy references and all tests pass:

```bash
# Run all tests
mix test
```
