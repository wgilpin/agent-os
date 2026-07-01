# Quickstart: Secure Secret Provisioning

This guide outlines how to configure, run, and test AgentOS with dynamic, runtime-provisioned credentials.

## 1. Configure Host Environment
To provision model API keys, set the following environment variables in the host environment (or define them in a `.env` file at the root of the repository):

```bash
# Example environment configuration
export MODEL_KEY="your-openrouter-api-key"
export OUTBOUND_TOKEN="your-outbound-token"
```

## 2. Validation and Boot Diagnostics
At boot time, `AgentOS.CredentialSource` parses the environment. If `MODEL_KEY` is missing or contains only whitespace, the application will boot but output a critical warning log:

```text
18:00:00.000 [error] CRITICAL: Required model credential :model_key is missing or blank.
```

In addition, any subsequent inference calls will fail-closed and return:
```elixir
{:error, {:unknown_credential, :model_key}}
```

## 3. Verifying Sandbox Key Isolation
To confirm that model credentials have not leaked into the sandboxed agent processes:
1. Run any python agent workload.
2. Verify that the agent container's environment does not contain the `MODEL_KEY` or `OUTBOUND_TOKEN` environment variables.
