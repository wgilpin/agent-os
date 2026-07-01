# Research Notes: Consent Screen UI

## Decision: LiveView Router Mounting and Parameter Extraction
- **Decision**: Mount `AgentOSWeb.ConsentLive` at `/consent` in `lib/agent_os_web/router.ex` within the default `:browser` pipeline scope:
  ```elixir
  live "/consent", ConsentLive, :index
  ```
- **Rationale**: Keeps the route simple and handles the path to the manifest file as a query parameter (e.g. `?manifest=manifests/discovery.md`). Query parameters automatically avoid route matching collision issues when the manifest path contains slashes or dots.
- **Alternatives Considered**: Matching path parameters (e.g., `/consent/*manifest_path`). However, route globbing makes extracting additional options harder and complicates path sanitization in Phoenix routing.

## Decision: Handling capability registry loud-failure contract
- **Decision**: In `ConsentLive.mount/3`, load the manifest and fetch entries within a `try/rescue` block:
  ```elixir
  try do
    # Load manifest and parse entries
    case AgentOS.Manifest.load(manifest_path) do
      {:ok, manifest} ->
        entries = AgentOS.CapabilityRender.entries(manifest)
        # Assign values to socket
      {:error, reason} ->
        # Assign error status
    end
  rescue
    e in RuntimeError ->
      # Capture the loud error from CapabilityRender.entries/1 when connector is unregistered
      assign(socket, status: :error, error_message: e.message)
  end
  ```
- **Rationale**: Keeps the registry lookup failure loud and explicit, surfacing the exact runtime exception to the user on the screen.
- **Alternatives Considered**: Pre-validating connectors in the LiveView. This was rejected because it would duplicate the validation logic already present in `CapabilityRender` and violate the single source of truth constraint.

## Decision: Resolving Pending Approvals and Resuming Execution
- **Decision**: When the LiveView mounts, search the `pending_approvals` StateStore snapshot for any approval entry where `action.method` matches the requested `manifest_path` or the agent's name matches:
  ```elixir
  pending_store = AgentOS.StateStore.snapshot("pending_approvals")
  approvals = Map.get(pending_store, :approvals, %{})
  
  # Find matching ref
  matching_ref = Enum.find_value(approvals, nil, fn {ref, %{action: action}} ->
    if action.method == manifest_path, do: ref, else: nil
  end)
  ```
  On **Approve**:
  1. Record provenance status as `:reviewed_human` with the manifest hash:
     ```elixir
     AgentOS.Provisioner.record_provenance(agent_name, :reviewed_human, hash)
     ```
  2. If `matching_ref` is present, submit approval trigger:
     ```elixir
     AgentOS.TriggerGateway.submit_sync({:approval, :approve, matching_ref})
     ```
  3. If no pending approval ref is found (e.g. developer testing, or stage-2 manifest preview), transition the UI to approved but do not submit to TriggerGateway since there is no ref to resume.
  On **Reject**:
  1. If `matching_ref` is present, submit denial trigger:
     ```elixir
     AgentOS.TriggerGateway.submit_sync({:approval, :deny, matching_ref})
     ```
  2. Do not execute or deploy the agent. Transition the UI to a rejected state.
- **Rationale**: Reuses the deterministic `TriggerGateway` and `Effector` channels, guaranteeing that only validated and approved actions execute.

## Decision: Visual Styling and conventions
- **Decision**: Append custom CSS selectors directly to `priv/static/app.css` using the design system's colors (e.g., `--color-bg-deep`, `--color-card-bg`, etc.). Emphasize `:external` danger tier using a bold red badge, `:local` with amber, and `:read_only` with green/blue. Group or sort capability entries so `:external` or mutating capabilities are displayed first.
- **Rationale**: Maintains styling consistency and adheres to the project's constraint of having no Tailwind or assets compilation pipeline.
