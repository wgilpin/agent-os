# Quickstart: HTTP Client & OpenRouter Transport

This guide outlines how to configure, run, and test the real OpenRouter integration in Agent OS.

## 1. Credentials Configuration

To run live queries in development (outside of the unit test suite), set the `MODEL_KEY` environment variable before starting the application:

```bash
export MODEL_KEY="sk-or-v1-your-openrouter-key"
```

The substrate reads this key automatically via `AgentOS.CredentialProxy`.

## 2. Dependency Verification

Verify that dependencies are retrieved and compiled:

```bash
mix deps.get
mix compile
```

## 3. Interactive Shell Testing

You can trigger a real model completion manually from the interactive Elixir terminal:

```bash
iex -S mix
```

Register a temporary token and make an inference completion request:

```elixir
# Setup test context
alias AgentOS.InferenceBroker
alias AgentOS.Manifest
alias AgentOS.Manifest.Spend

token = "manual-test-token"
manifest = %Manifest{
  purpose: "Manual testing",
  owner: "human",
  supervision: "restart-once-and-alert",
  grants: [],
  spend: %Spend{cap: 50_000, window: :daily, on_breach: :kill},
  mounts: [],
  triggers: []
}

InferenceBroker.register(token, "test_agent", manifest)

# Request completion
req = %{
  run_token: token,
  model: "google/gemini-2.5-flash", # must be priced in config
  messages: [%{role: "user", content: "Hello, OpenRouter!"}]
}

InferenceBroker.complete(req)
```

## 4. Running the Tests

To verify code changes without contacting the actual OpenRouter API, run the standard test suite:

```bash
mix test test/agent_os/inference_broker_test.exs
```
