defmodule AgentOSWeb.ConsentLive do
  @moduledoc """
  Phoenix LiveView screen rendering deterministic capability grants of a manifest.
  Allows explicit human Approve/Reject decisions before code execution/deployment.
  """
  use Phoenix.LiveView

  @impl true
  def mount(params, _session, socket) do
    manifest_path = params["manifest"] || params["manifest_path"]

    if is_nil(manifest_path) || String.trim(manifest_path) == "" do
      {:ok,
       assign(socket,
         manifest_path: nil,
         agent_name: nil,
         manifest: nil,
         entries: [],
         ref: nil,
         status: :error,
         error_message: "No manifest file path specified."
       )}
    else
      try do
        case AgentOS.Manifest.load(manifest_path) do
          {:ok, manifest} ->
            # Get capability entries from the registry mapping
            entries = AgentOS.CapabilityRender.entries(manifest)

            # Sort entries by danger tier: external (3), local (2), read_only (1)
            sorted_entries = Enum.sort_by(entries, &danger_weight/1, :desc)

            # Resolve matching pending approval reference
            ref = find_pending_approval_ref(manifest_path)

            {:ok,
             assign(socket,
               manifest_path: manifest_path,
               agent_name: Path.basename(manifest_path, ".md"),
               manifest: manifest,
               entries: sorted_entries,
               ref: ref,
               status: :pending,
               error_message: nil
             )}

          {:error, reason} ->
            {:ok,
             assign(socket,
               manifest_path: manifest_path,
               agent_name: nil,
               manifest: nil,
               entries: [],
               ref: nil,
               status: :error,
               error_message: "Could not load manifest: #{inspect(reason)}"
             )}
        end
      rescue
        e in RuntimeError ->
          # Surface the unregistered connector registry lookup loud-failure contract
          {:ok,
           assign(socket,
             manifest_path: manifest_path,
             agent_name: nil,
             manifest: nil,
             entries: [],
             ref: nil,
             status: :error,
             error_message: e.message
           )}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="consent-container">
      <div class="consent-card">
        <%= if @status == :error do %>
          <div class="error-banner">
            <h2>Capability Loading Error</h2>
            <p>The manifest could not be loaded or parsed due to the following failure:</p>
            <pre><%= @error_message %></pre>
          </div>
        <% else %>
          <div class="consent-card-header">
            <h1>Consent Required: <%= @agent_name %></h1>
            <p class="purpose-text"><strong>Purpose:</strong> <%= @manifest.purpose %></p>
          </div>

          <div class="spend-cap-banner">
            <span class="label">Spend Cap (<%= @manifest.spend.window %>)</span>
            <span class="value">$<%= :erlang.float_to_binary(@manifest.spend.cap / 1_000_000, [:compact, decimals: 6]) %></span>
          </div>

          <h2 class="consent-section-title">Requested Capabilities</h2>
          <div class="capabilities-group">
            <%= for entry <- @entries do %>
              <div class="capability-item">
                <div class="capability-item-header">
                  <span class="capability-phrase"><%= entry.phrase %></span>
                  <span class={"danger-badge danger-badge-#{entry.danger}"}><%= entry.danger %></span>
                </div>
                <%= if entry.recipients || entry.methods do %>
                  <div class="capability-details">
                    <%= if entry.recipients do %>
                      <div class="capability-detail-row">
                        <span class="capability-detail-label">Recipients:</span>
                        <span><%= inspect(entry.recipients) %></span>
                      </div>
                    <% end %>
                    <%= if entry.methods do %>
                      <div class="capability-detail-row">
                        <span class="capability-detail-label">Methods:</span>
                        <span><%= inspect(entry.methods) %></span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%= if @status == :pending do %>
            <div class="consent-actions">
              <button class="btn-approve" phx-click="approve">Approve</button>
              <button class="btn-reject" phx-click="reject">Reject</button>
            </div>
          <% end %>

          <%= if @status == :approved do %>
            <div class="decision-banner decision-banner-approved">
              <h2>Deployment Approved!</h2>
              <p>Consent has been recorded successfully. Downstream deployment has been unblocked.</p>
            </div>
          <% end %>

          <%= if @status == :rejected do %>
            <div class="decision-banner decision-banner-rejected">
              <h2>Deployment Rejected</h2>
              <p>This deployment has been rejected by the user. Downstream execution is blocked.</p>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("approve", _params, socket) do
    if socket.assigns.status == :pending do
      # 1. Compute manifest hash
      hash = AgentOS.Provisioner.manifest_hash(socket.assigns.manifest_path)

      # 2. Record approved provenance state
      :ok = AgentOS.Provisioner.record_provenance(socket.assigns.agent_name, :reviewed_human, hash)

      # 3. Resume the deploy execution via TriggerGateway approval if ref exists
      if socket.assigns.ref do
        AgentOS.TriggerGateway.submit_sync({:approval, :approve, socket.assigns.ref})
      end

      {:noreply, assign(socket, status: :approved)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reject", _params, socket) do
    if socket.assigns.status == :pending do
      # 1. Resume the deny execution via TriggerGateway if ref exists
      if socket.assigns.ref do
        AgentOS.TriggerGateway.submit_sync({:approval, :deny, socket.assigns.ref})
      end

      # No code executes on the reject path

      {:noreply, assign(socket, status: :rejected)}
    else
      {:noreply, socket}
    end
  end

  # Helper to assign weight to danger levels for ordering
  defp danger_weight(entry) do
    case entry.danger do
      :external -> 3
      :local -> 2
      :read_only -> 1
      _ -> 0
    end
  end

  # Helper to lookup matching pending approvals from StateStore
  defp find_pending_approval_ref(manifest_path) do
    pending_store = AgentOS.StateStore.snapshot("pending_approvals")
    approvals = Map.get(pending_store, :approvals, %{})

    Enum.find_value(approvals, nil, fn {ref, %{action: action}} ->
      if action.method == manifest_path, do: ref, else: nil
    end)
  end
end
