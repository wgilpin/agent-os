# Quickstart: Review Modes and Deterministic Envelope Predicate

This quickstart guide demonstrates how to invoke and test the deploy-time rail.

## Command Line & Console Interface

Deployments can be executed and approved through the Elixir Interactive Shell (`iex`):

### 1. Triggering a Deployment

Call `AgentOS.Provisioner.deploy/3` with the path to the manifest and the desired review mode:

```elixir
# Deploy in Always Review mode (will block)
{:blocked, ref} = AgentOS.Provisioner.deploy("manifests/discovery.md", :always_review)

# Deploy in Review If Risky mode (blocks because discovery.md has external egress and cap is > 100k)
{:blocked, ref} = AgentOS.Provisioner.deploy("manifests/discovery.md", :review_if_risky)

# Deploy in Dangerously Skip Review mode (proceeds instantly)
{:ok, :dangerously_skipped} = AgentOS.Provisioner.deploy("manifests/discovery.md", :dangerously_skip_review)
```

### 2. Resolving a Blocked Deployment

When a deployment is blocked, a pending approval reference is returned (e.g. `ref_deploy_discovery_1`). You can approve or deny it using the `TriggerGateway`:

```elixir
# Approve the blocked deployment (triggers provenance recording + run execution)
AgentOS.TriggerGateway.submit({:approval, :approve, "ref_deploy_discovery_1"})

# Deny the blocked deployment (clears approval without deploying)
AgentOS.TriggerGateway.submit({:approval, :deny, "ref_deploy_discovery_1"})
```

### 3. Checking Deploy Provenance

View the standing inventory to read the recorded deploy provenance:

```elixir
IO.puts(AgentOS.Inventory.render())
```

It will render the recorded provenance next to the capabilities view:

```text
Agent OS Standing Inventory
===========================
PURPOSE: Surface high-signal AI/ML content from the people-roster; read-and-digest only.
TRIGGERS: [%{at: "07:00", type: :time}, %{type: :message}, %{name: "bookmark_saved", type: :event}]
        CAPABILITIES:
          - WRITE TO YOUR LOCAL STATE STORE (methods: ["append"])
          - [EXTERNAL] SEND MESSAGES OUT TO EXTERNAL RECIPIENTS (recipients: ["owner-inbox"], methods: ["send"])
DEPLOY PROVENANCE: reviewed=human
MOUNTS: ["roster_trust"]
...
```

## Running Automated Tests

Run ExUnit tests verifying review modes, the envelope predicate, and gate persistence:

```bash
mix test test/agent_os/provisioner_test.exs
```
