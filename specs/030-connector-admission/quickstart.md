# Quickstart: Connector Admission + Compile-Isolated Plugins

This guide explains how to dynamically load, admit, and execute a third-party plugin connector.

## 1. Dynamic Plugin Setup

1. Write a separate Elixir module in a standalone file (e.g. `test/support/plugins/my_tool.ex`):
```elixir
defmodule AgentOS.Connector.MyTool do
  @behaviour AgentOS.Connector
  
  def metadata do
    %{
      name: "my_tool",
      mutating?: true,
      requires_approval?: false,
      credential: :tool_secret,
      cost: 0
    }
  end
  
  def scope(_), do: %AgentOS.Manifest.Grant{connector: "my_tool"}
  
  def execute(_, secret), do: {:ok, {:state_store, "roster_trust", {:append, :records, %{"secret" => secret}}}}
  
  def render(_), do: "MY TOOL"
end
```

2. Compile the standalone file to generate a `.beam` file:
```bash
elixirc -o data/plugins test/support/plugins/my_tool.ex
```

## 2. Admission & Discovery

At boot, the loader automatically scans the `data/plugins/` directory and loads `AgentOS.Connector.MyTool.beam`.

However, the connector is **not discoverable** until it is admitted.

To admit the tool and wire its credentials:

```elixir
# Admit the tool and map its :tool_secret credential to System Env "MY_CUSTOM_SECRET"
AgentOS.Connector.admit(AgentOS.Connector.MyTool, %{tool_secret: :my_custom_secret})
```

Once admitted:
1. `AgentOS.Connector.registry()` discovers the module.
2. `AgentOS.CredentialProxy` resolves `:tool_secret` via `System.get_env("MY_CUSTOM_SECRET")`.
3. The effector allows execution.

## 3. Running Verification Tests

```bash
# Run the admission and contract isolation tests
mix test test/agent_os/connector_admission_test.exs
```
