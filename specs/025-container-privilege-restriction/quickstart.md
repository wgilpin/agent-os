# Quickstart Guide: Hardened Sandbox Verification

This guide outlines how to compile and run tests to verify the hardened container sandbox.

## Prerequisites
- Docker daemon running on the local host.
- Elixir and Mix installed.

## Running Unit Tests
Unit tests verify the argument compilation logic in the `Sandbox` module and confirm that invalid configurations are rejected:
```bash
mix test test/agent_os/sandbox_test.exs
```

## Running Gated Integration Tests
Integration tests run real docker containers to verify hard constraints like Memory OOM kills and process limit enforcement (fork-bomb prevention):
```bash
mix test test/agent_os/isolation_test.exs --include docker
```

## Verifying Constraints Manually

To confirm the container user identity inside:
```elixir
alias AgentOS.Sandbox
alias AgentOS.PortRunner

sandbox = %Sandbox{
  image: "agent-discovery:dev",
  cidfile: "test_cidfile.txt",
  entrypoint: "id"
}

argv = Sandbox.build_argv(sandbox)
{:ok, stdout} = PortRunner.run("{}", "docker", argv)
IO.puts(stdout) # Should output uid=1000 gid=1000
```
