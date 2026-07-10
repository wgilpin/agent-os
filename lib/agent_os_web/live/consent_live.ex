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
      # Bare /consent (e.g. from the site nav): show the approval queue — every
      # non-system agent still waiting for the owner's consent, linking to its view.
      {:ok,
       assign(socket,
         manifest_path: nil,
         agent_name: nil,
         manifest: nil,
         entries: [],
         ref: nil,
         status: :index,
         awaiting: awaiting_agents(),
         error_message: nil
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

            agent_name = Path.basename(manifest_path, ".md")

            {:ok,
             assign(socket,
               manifest_path: manifest_path,
               agent_name: agent_name,
               manifest: manifest,
               entries: sorted_entries,
               ref: ref,
               status: :pending,
               code_missing: not File.exists?(Path.join(["agents", agent_name, "main.py"])),
               gate_error: nil,
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
        <a href="/inventory" class="consent-back-link">← Back to agents</a>
        <%= if @status == :index do %>
          <div class="consent-card-header">
            <h1>Approvals</h1>
            <p class="purpose-text">Agents waiting for your consent before they can deploy and run.</p>
          </div>
          <%= if Enum.empty?(@awaiting) do %>
            <p class="approval-queue-empty">Nothing is waiting for your approval right now.</p>
          <% else %>
            <div class="approval-queue">
              <%= for item <- @awaiting do %>
                <a href={"/consent?" <> URI.encode_query(manifest: item.path)} class="approval-queue-item">
                  <span class="approval-queue-name"><%= humanize_name(item.agent_name) %></span>
                  <span class="approval-queue-cta">Review →</span>
                </a>
              <% end %>
            </div>
          <% end %>
        <% end %>
        <%= if @status == :error do %>
          <div class="error-banner">
            <h2>Capability Loading Error</h2>
            <p>The manifest could not be loaded or parsed due to the following failure:</p>
            <pre><%= @error_message %></pre>
          </div>
        <% end %>
        <%= if @manifest do %>
          <div class="consent-card-header">
            <h1>Consent Required</h1>
            <p class="agent-name-sub" title={@agent_name}><%= humanize_name(@agent_name) %></p>
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
                  <span class="capability-phrase"><%= display_phrase(entry.phrase) %></span>
                  <span class={"danger-badge danger-badge-#{entry.danger}"}><%= entry.danger %></span>
                </div>
                <%= if entry.recipients || entry.methods do %>
                  <div class="capability-details">
                    <%= if entry.recipients do %>
                      <div class="capability-detail-row">
                        <span class="capability-detail-label">Sends to</span>
                        <span><%= humanize_terms(entry.recipients) %></span>
                      </div>
                    <% end %>
                    <%= if entry.methods do %>
                      <div class="capability-detail-row">
                        <span class="capability-detail-label">Can</span>
                        <span><%= humanize_terms(entry.methods) %></span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%= if @status == :pending and Map.get(assigns, :code_missing, false) do %>
            <div class="code-missing-warning" role="alert">
              <strong>This agent has no generated code.</strong>
              It cannot run or be approved until it is created again
              from the Create agent page. Consider deleting it from the inventory instead.
            </div>
          <% end %>

          <%= if @status == :pending and Map.get(assigns, :gate_error) do %>
            <div class="gate-error-banner" role="alert">
              <strong>Not approved:</strong> <%= @gate_error %>
              <%= if not Map.get(assigns, :code_missing, false) do %>
                <!-- Agent has code: the remedy is to re-run its checks from the inventory (FR-006). -->
                <.link navigate="/inventory" class="gate-error-link">Re-run its checks from the inventory.</.link>
              <% end %>
            </div>
          <% end %>

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
      review_mode = Application.get_env(:agent_os, :review_mode, :always_review)

      # Fail closed BEFORE recording :reviewed_human provenance: recorded approval
      # routes Provisioner.deploy into its idempotent re-deploy path, so the gate
      # must be checked here, not after.
      case AgentOS.Provisioner.deploy_gate(socket.assigns.agent_name, review_mode) do
        :ok ->
          do_approve(socket)

        {:error, reason} ->
          {:noreply,
           assign(socket, gate_error: gate_error_text(reason, socket.assigns.code_missing))}
      end
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

  defp do_approve(socket) do
    # 1. Compute manifest hash
    hash = AgentOS.Provisioner.manifest_hash(socket.assigns.manifest_path)

    # 2. Record approved provenance state
    :ok =
      AgentOS.Provisioner.record_provenance(socket.assigns.agent_name, :reviewed_human, hash)

    # 3. Resume the deploy execution via TriggerGateway approval if ref exists.
    #    With no pending deploy action to resume (the pipeline never queued one),
    #    the human approval IS the deploy decision: Provisioner.deploy's healing
    #    path lands the registry record for the just-recorded approved provenance,
    #    then startup fires and time triggers arm exactly as on a normal deploy.
    if socket.assigns.ref do
      AgentOS.TriggerGateway.submit_sync({:approval, :approve, socket.assigns.ref})
    else
      complete_deploy(socket.assigns.agent_name, socket.assigns.manifest_path)
    end

    {:noreply, assign(socket, status: :approved)}
  end

  # Human-readable copy for a deploy-gate refusal on the approve button (spec 043, FR-006):
  # names the reason, then appends the appropriate remedy. For an agent WITH code the remedy
  # is the "Re-run its checks from the inventory" link rendered in the banner; for an orphan
  # (no code) there is nothing to check, so the text directs re-create or delete.
  defp gate_error_text(reason, code_missing?) do
    base = gate_reason_text(reason)

    if code_missing? do
      base <> " Re-create it from the Create agent page, or delete it from the inventory."
    else
      base
    end
  end

  defp gate_reason_text(:missing_verdict),
    do:
      "this agent's safety checks (code check and security review) haven't completed, " <>
        "so it can't be approved."

  defp gate_reason_text(:stale_verdict),
    do:
      "this agent's code doesn't match the code its safety checks reviewed " <>
        "(it may have been changed, regenerated, or never generated), so it can't be approved."

  defp gate_reason_text(:security_review_failed),
    do: "this agent's security review did not pass, so it can't be approved."

  defp gate_reason_text(:judge_failed),
    do: "this agent's code check (blind compliance test) did not pass, so it can't be approved."

  defp gate_reason_text(:both_failed),
    do: "this agent failed both its code check and its security review, so it can't be approved."

  # Human-readable text helpers shared with the inventory dashboard.
  defdelegate humanize_name(name), to: AgentOSWeb.HumanText
  defdelegate display_phrase(phrase), to: AgentOSWeb.HumanText
  defdelegate humanize_terms(terms), to: AgentOSWeb.HumanText

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

  # Every non-system agent that is not deployed: reviewing and approving it here is
  # always the path to deployment (including agents approved earlier whose deploy never
  # completed). Store lookups tolerate absent stores (minimal test trees).
  defp awaiting_agents do
    "manifests/*.md"
    |> Path.wildcard()
    |> Enum.reject(&AgentOS.AgentLifecycle.system_agent?(Path.basename(&1, ".md")))
    |> Enum.filter(fn path ->
      agent_name = Path.basename(path, ".md")
      is_nil(safe_lookup(fn -> AgentOS.DeploymentRegistry.get(agent_name) end))
    end)
    |> Enum.map(fn path -> %{path: path, agent_name: Path.basename(path, ".md")} end)
    |> Enum.sort_by(& &1.agent_name)
  end

  defp safe_lookup(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Completes a consent-approved deploy that has no pending action to resume. Tolerant of
  # absent processes (minimal test trees) — in production the failure is logged loudly.
  defp complete_deploy(agent_name, manifest_path) do
    case AgentOS.Provisioner.deploy(manifest_path, :always_review) do
      {:ok, _provenance} ->
        :ok = AgentOS.TriggerArming.fire_startup(agent_name, manifest_path)
        AgentOS.TriggerArming.rearm(agent_name)
        :ok

      other ->
        require Logger

        Logger.error(
          "ConsentLive: approve for #{inspect(agent_name)} could not complete deploy: " <>
            "#{inspect(other)}"
        )

        :ok
    end
  rescue
    error ->
      require Logger
      Logger.error("ConsentLive: deploy completion failed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      require Logger
      Logger.error("ConsentLive: deploy completion unavailable: #{inspect(reason)}")
      :ok
  end
end
