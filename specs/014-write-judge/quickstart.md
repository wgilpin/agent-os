# Quickstart: Generating and Running the Judge

How to use the Stage 3 Judge components programmatically.

## Usage

### 1. Synthesizing the Judge (Stage 3)

Run the generator to construct `judge_spec.json` before the agent body exists.

```elixir
# Load the human-confirmed manifest from Stage 2
manifest_path = "manifests/my_agent.md"
{:ok, manifest} = AgentOS.Manifest.load(manifest_path)

# Generate and save the judge spec using the InferenceBroker
agent_name = "my_agent"
{:ok, test_spec} = AgentOS.Pipeline.Stage3.generate(agent_name, manifest, run_token: "synthesis-token-abc")

# The spec is written to agents/my_agent/judge_spec.json
```

### 2. Running the Judge (Stage 6 / Deploy-Time)

At deploy-time, run the test runner to execute the agent, intercept proposed actions, and score compliance.

```elixir
# Execute the agent and score it via LLM-as-judge
{:ok, verdict} = AgentOS.Pipeline.Stage3.run("my_agent", run_token: "eval-token-xyz")

case verdict.status do
  :pass ->
    IO.puts("Pass: #{verdict.reasoning}")
    # Proceed to security review/deploy

  :fail ->
    IO.puts("Fail: #{verdict.reasoning}")
    # Halt deployment

  :error ->
    IO.puts("Error: #{verdict.reasoning}")
    # Fail safe: halt deployment
end
```

### 3. Rendering Inventory Results

The status of the judge is automatically saved in `StateStore` under `"judge_results"`. `AgentOS.Inventory.render/1` reads it and prints it out.

```elixir
# Print inventory output
IO.puts(AgentOS.Inventory.render())

# Output snippet:
# Agent OS Standing Inventory
# ===========================
# PURPOSE: watch and report recruiter emails
# ...
# JUDGE: pass (last run: 2026-06-30T22:15:00Z)
# Scope: CODE-MATCHES-MANIFEST. This does not verify human intent correctness.
```
