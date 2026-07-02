# Research Notes: Pluggable Connector Registry

## Design Decisions & Technical Feasibility

### Dynamic Module Auto-Discovery
To implement zero-config registration where developers can add a capability by dropping a single module into `lib/agent_os/connector/`, we must dynamically discover these modules at boot time.
- **Mechanism**: Use `Application.spec(:agent_os, :modules)` to retrieve all modules defined within the `agent_os` OTP application context.
- **Filter**: For each module, ensure it is loaded using `Code.ensure_loaded/1` and verify if `AgentOS.Connector` is in its compiler-defined attributes under `:behaviour` or `:behavior`.
- **Registry compilation**: At application startup, the `AgentOS.Connector` module scans all modules, queries their `metadata/0` callback, and constructs the map structure required by the gate.

### Behaviour Definition
The `AgentOS.Connector` behaviour will require four callbacks:
1. `metadata/0`: Returns a capability metadata map:
   ```elixir
   @callback metadata() :: %{
     name: String.t(),
     mutating?: boolean(),
     requires_approval?: boolean(),
     credential: atom() | nil,
     cost: integer()
   }
   ```
2. `scope/1`: Maps boundaries to a manifest grant:
   ```elixir
   @callback scope(boundaries :: map()) :: AgentOS.Manifest.Grant.t()
   ```
3. `execute/2`: Executes the action under a generic effector dispatch path:
   ```elixir
   @callback execute(action :: AgentOS.ProposedAction.t(), secret :: String.t() | nil) :: :ok | {:error, term()}
   ```
4. `render/1`: Renders the deterministic consent line for a grant:
   ```elixir
   @callback render(grant :: AgentOS.Manifest.Grant.t()) :: String.t()
   ```

### Fault-Containment and Isolation
To prevent a single connector crash or hang from taking down the OS or run worker:
- **Task Supervisor**: Introduce a dedicated `Task.Supervisor` named `AgentOS.ConnectorSupervisor` to the `AgentOS.Application` supervision tree.
- **Execution isolation**: The effector will spawn connector execution using `Task.Supervisor.async_nolink/3` under the new supervisor.
- **Crash protection**: The execution closure is wrapped in a `try/rescue/catch` block.
- **Timebox enforcement**: The effector yields to the task with a strict timeout (e.g. 5 seconds). If it times out, the task is forcefully killed via `Task.shutdown/2` and a fail-closed `{:error, :timeout}` error is returned.

### Generic Credential Resolution
To eliminate hardcoded credential cases, any connector declaring a credential ID (e.g. `:outbound_token`) will have it resolved post-approval:
- Iterate over the connector's declared credential atom.
- Resolve it dynamically from system environment variable (mapping atom to uppercase string, e.g., `:outbound_token` -> `OUTBOUND_TOKEN`) or the configuration map in application settings.

## Alternatives Considered
1. **Dynamic directory scanner**: Using `File.ls/1` on the folder.
   - *Rejected because*: Directory scanning is fragile in compiled/packaged BEAM releases where the source folder path may not exist or be accessible. `Application.spec/2` is the standard OTP way.
2. **Synchronous task execution**: Calling `execute/2` in the worker process.
   - *Rejected because*: An infinite loop or raise in the connector would crash or hang the entire run worker process, violating the fault-isolation invariant.
