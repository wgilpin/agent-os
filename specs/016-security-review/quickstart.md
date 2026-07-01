# Quickstart: Stage 5 Security Review Agent

This guide demonstrates how to invoke and test the Stage 5 security review agent.

---

## 1. Running the Review Programmatically (from IEx)

```elixir
alias AgentOS.Manifest
alias AgentOS.Pipeline.Stage5

# Load or project the manifest
manifest = %Manifest{purpose: "...", grants: [...], spend: ...}

# Read target agent files
code_files = %{
  "main.py" => File.read!("agents/discovery/main.py"),
  "models.py" => File.read!("agents/discovery/models.py")
}

# Run the review using a registered run token
case Stage5.review("discovery", manifest, code_files, run_token: "my-active-run-token") do
  {:ok, %Stage5.Verdict{status: :pass, reasoning: why}} ->
    IO.puts("Security check passed: #{why}")

  {:ok, %Stage5.Verdict{status: :fail, reasoning: why}} ->
    IO.puts("Security threat detected: #{why}")

  {:error, reason} ->
    IO.puts("Execution error: #{inspect(reason)}")
end
```

---

## 2. Unit Testing via Mock Provider (Constitution IV Seam)

Use the `:provider_fn` seam to mock LLM interactions in ExUnit tests to prevent live network calls:

```elixir
# test/agent_os/pipeline/stage5_review_test.exs
test "returns pass verdict for benign code", %{manifest: manifest} do
  mock_provider = fn _model, _messages, _secret ->
    %{
      input_tokens: 120,
      output_tokens: 80,
      completion: Jason.encode!(%{
        status: "pass",
        reasoning: "No capability breach or credential leak found in the code."
      })
    }
  end

  assert {:ok, %Verdict{status: :pass}} =
           Stage5.review("test_agent", manifest, code_files,
             run_token: "token-123",
             provider_fn: mock_provider
           )
end
```

---

## 3. Querying Verdicts from Inventory

```elixir
# Retrieve the verdict from StateStore
case AgentOS.StateStore.get("security_review_results", "discovery") do
  nil ->
    IO.puts("Agent has not been reviewed.")

  %Verdict{status: status, reasoning: reasoning} ->
    IO.puts("Status: #{status}, Reasoning: #{reasoning}")
end
```
