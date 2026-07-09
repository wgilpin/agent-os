defmodule AgentOSWeb.InventoryLive do
  @moduledoc """
  Phoenix LiveView screen rendering the standing inventory dashboard.
  Lists all provisioned agents with their roster, spend status, capabilities,
  and legible run trace audit log. Deployment state comes from the durable
  deployment registry (FR-008), updated live via PubSub with the 5s poll kept
  as fallback; deployed agents with a message trigger offer a test-fire routed
  through the normal TriggerGateway dispatch path (FR-009).
  """
  use Phoenix.LiveView

  alias AgentOS.DeploymentRegistry
  alias AgentOS.Inventory
  alias AgentOS.Pipeline.ProgressEvent
  alias AgentOS.RunLog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_tick()
      # Live updates on pipeline/deployment changes; the poll remains a fallback.
      Phoenix.PubSub.subscribe(AgentOS.PubSub, ProgressEvent.all_topic())
    end

    socket =
      socket
      |> assign_agents_data()
      |> assign(last_updated: DateTime.utc_now(), fire_result: nil)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="inventory-dashboard-container">
      <header class="dashboard-header">
        <div class="header-content">
          <h1>Agent OS Standing Inventory</h1>
          <span class="last-updated-badge">
            Last Updated: <%= Calendar.strftime(@last_updated, "%Y-%m-%d %H:%M:%S UTC") %>
          </span>
        </div>
      </header>

      <div class="agent-grid">
        <%= if Enum.empty?(@agents_data) do %>
          <div class="no-agents-card">
            <h2>No Provisioned Agents Found</h2>
            <p>Make sure you have valid agent manifests under manifests/*.md</p>
          </div>
        <% else %>
          <%= for agent <- @agents_data do %>
            <div class="agent-card" id={"agent-card-#{agent.agent_name}"}>
              
              <!-- Roster Panel -->
              <section class="panel roster-panel">
                <div class="panel-header">
                  <h2>
                    <span class="agent-name-highlight" title={agent.agent_name}>
                      <%= AgentOSWeb.HumanText.humanize_name(agent.agent_name) %>
                    </span>
                  </h2>
                </div>
                <div class="metadata-content">
                  <div class="meta-row deployment-row">
                    <strong>Deployment:</strong>
                    <span class={"badge badge-deployment badge-deployment-#{deployment_status_class(agent.deployment)}"}>
                      <%= deployment_status_label(agent.deployment) %>
                    </span>
                  </div>
                  <p class="meta-row"><strong>Purpose:</strong> <%= agent.purpose %></p>
                  <div class="meta-row trigger-row">
                    <strong>Triggers:</strong>
                    <div class="trigger-pills-group">
                      <%= for trigger_label <- format_triggers(agent.triggers) do %>
                        <span class="trigger-pill"><%= trigger_label %></span>
                      <% end %>
                    </div>
                  </div>
                  <p class="meta-row"><strong>Owner / Supervision:</strong> <%= agent.owner %> / <%= agent.supervision %></p>
                  
                  <div class="meta-row provenance-row">
                    <strong>Approval:</strong>
                    <span class={"badge badge-provenance badge-provenance-#{provenance_status_class(agent.provenance)}"}>
                      <%= provenance_status_label(agent.provenance) %>
                    </span>
                  </div>

                  <div class="meta-row combined-status-row">
                    <strong title="Automated pre-deploy checks and ongoing behaviour monitoring">Checks:</strong>
                    <div class="badge-group">
                      <span
                        class={"badge badge-judge-#{judge_status_class(agent.judge)}"}
                        title="Does the agent's code do what you asked for?"
                      >
                        Code check: <%= judge_status_label(agent.judge) %>
                      </span>
                      <span
                        class={"badge badge-security-#{security_status_class(agent.security_review)}"}
                        title="Is the agent's code safe to run?"
                      >
                        Safety check: <%= security_status_label(agent.security_review) %>
                      </span>
                      <span
                        class={"badge badge-conformance-#{conformance_status_class(agent.conformance)}"}
                        title="Has the agent been behaving as promised in its past runs?"
                      >
                        Behaviour: <%= conformance_status_label(agent.conformance) %>
                      </span>
                    </div>
                  </div>
                </div>
              </section>

              <!-- Spend Panel -->
              <section class="panel spend-panel">
                <div class="panel-header">
                  <h2>Spend Status</h2>
                </div>
                <div class="spend-content">
                  <%= if agent.spend_cap <= 0 do %>
                    <div class="spend-metric-container spend-warning-box">
                      <div class="spend-values">
                        <span class="spent-value">$0 limit</span>
                      </div>
                      <div class="spend-window">
                        This agent's spending limit is $0, so it can never do anything.
                        It was created before spending limits were checked — delete it
                        and create it again.
                      </div>
                    </div>
                  <% else %>
                    <div class={"spend-metric-container #{spend_class(agent.spent, agent.spend_cap)}"}>
                      <div class="spend-values">
                        <span class="spent-value"><%= format_dollars(agent.spent) %></span>
                        <span class="spend-slash">/</span>
                        <span class="cap-value"><%= format_dollars(agent.spend_cap) %></span>
                      </div>
                      <div class="spend-window">per <%= agent.spend_window %></div>
                    </div>

                    <%= if agent.spent >= agent.spend_cap do %>
                      <div class="spend-alert-msg spend-breached">
                        <strong>BREACH:</strong> Agent spend has exceeded the allocated cap!
                      </div>
                    <% else %>
                      <%= if agent.spent >= agent.spend_cap * 0.8 do %>
                        <div class="spend-alert-msg spend-warning">
                          <strong>WARNING:</strong> Agent spend is near the cap (&gt;= 80%).
                        </div>
                      <% end %>
                    <% end %>
                  <% end %>
                </div>
              </section>

              <!-- Audit Log & Conformance Panel -->
              <section class="panel audit-panel">
                <div class="panel-header">
                  <h2>Audit Log & Conformance</h2>
                </div>

                <!-- Run Records Table -->
                <div class="runs-section">
                  <h3>Recent Executions</h3>
                  <%= if Enum.empty?(agent.recent_runs) do %>
                    <p class="no-runs-text">No runs recorded.</p>
                  <% else %>
                    <div class="table-wrapper">
                      <table class="run-records-table">
                        <thead>
                          <tr>
                            <th>Status</th>
                            <th>Actions</th>
                            <th>Trigger</th>
                            <th>In / Dropped</th>
                            <th>Note / Cause</th>
                          </tr>
                        </thead>
                        <tbody>
                          <%= for run <- agent.recent_runs do %>
                            <tr class={"run-row run-status-#{run.status}"}>
                              <td>
                                <span class={"badge run-status-badge run-status-badge-#{run.status}"}>
                                  <%= run.status %>
                                </span>
                              </td>
                              <td class="numeric-cell"><%= run.actions %></td>
                              <td><code class="trigger-code"><%= run.trigger %></code></td>
                              <td class="numeric-cell"><%= run.items_in %> / <%= run.items_dropped %></td>
                              <td class="note-cell">
                                <%= run.note %>
                                <%= if run.breached_count > 0, do: " (breached: #{run.breached_count})" %>
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    </div>
                  <% end %>
                </div>

                <!-- Conformance Flags -->
                <%= if agent.conformance && agent.conformance.status == :flagged do %>
                  <div class="conformance-flags-section">
                    <h3>Raised Flags</h3>
                    <ul class="conformance-flags-list">
                      <%= for flag <- agent.conformance.flags do %>
                        <li class={"flag-item flag-severity-#{flag.severity}"}>
                          <span class="flag-axis">[<%= flag_axis(flag.type) %>]</span>
                          <span class="flag-type"><%= String.replace(to_string(flag.type), "_", "-") %></span>
                          <span class="flag-desc">— <%= flag.description %></span>
                        </li>
                      <% end %>
                    </ul>
                  </div>
                <% end %>

                <!-- Pending Approvals -->
                <%= if not Enum.empty?(agent.pending_approvals) do %>
                  <div class="pending-approvals-section">
                    <h3>Pending Approvals</h3>
                    <ul class="pending-approvals-list">
                      <%= for app <- agent.pending_approvals do %>
                        <li class="pending-approval-item">
                          <code class="approval-ref"><%= app.ref %></code>
                          <span class="approval-action-type"><%= app.action.type %></span>
                          <%= if app.action.recipient do %>
                            <span class="approval-arrow">→</span>
                            <span class="approval-recipient"><%= app.action.recipient %></span>
                          <% end %>
                        </li>
                      <% end %>
                    </ul>
                  </div>
                <% end %>

                <!-- Message-trigger test-fire (FR-009): only for deployed-active
                     agents that declare a message trigger; routed through the
                     normal TriggerGateway dispatch path. -->
                <%= if deployed_active?(agent.deployment) and has_message_trigger?(agent.triggers) do %>
                  <div class="test-fire-section">
                    <h3>Test-Fire Message Trigger</h3>
                    <form phx-submit="test_fire" class="test-fire-form">
                      <input type="hidden" name="agent" value={agent.agent_name} />
                      <input
                        type="text"
                        name="payload"
                        placeholder="Test payload…"
                        required
                        style="padding: 6px; width: 60%;"
                      />
                      <button type="submit" class="btn-primary">Fire</button>
                    </form>
                    <%= if @fire_result && elem(@fire_result, 0) == agent.agent_name do %>
                      <p class="test-fire-result"><code><%= elem(@fire_result, 1) %></code></p>
                    <% end %>
                  </div>
                <% end %>

                <!-- Capabilities -->
                <div class="capabilities-section">
                  <h3>Capabilities</h3>
                  <div class="capabilities-grid">
                    <%= for entry <- agent.capabilities do %>
                      <div class={"cap-item-box danger-badge-#{entry.danger}"}>
                        <div class="cap-meta">
                          <span class="cap-connector"><%= AgentOSWeb.HumanText.display_phrase(entry.phrase) %></span>
                          <span class={"danger-tag danger-tag-#{entry.danger}"}><%= String.upcase(to_string(entry.danger)) %></span>
                        </div>
                        <%= if entry.recipients || entry.methods do %>
                          <div class="cap-scopes">
                            <%= if entry.recipients do %>
                              <span class="scope-group"><span class="scope-key">Sends to</span> <span class="scope-val"><%= AgentOSWeb.HumanText.humanize_terms(entry.recipients) %></span></span>
                            <% end %>
                            <%= if entry.recipients && entry.methods, do: " · " %>
                            <%= if entry.methods do %>
                              <span class="scope-group"><span class="scope-key">Can</span> <span class="scope-val"><%= AgentOSWeb.HumanText.humanize_terms(entry.methods) %></span></span>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>

              </section>

            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_info(:tick, socket) do
    schedule_tick()

    socket =
      socket
      |> assign_agents_data()
      |> assign(last_updated: DateTime.utc_now())

    {:noreply, socket}
  end

  @impl true
  def handle_info({:pipeline_progress, %ProgressEvent{}}, socket) do
    # Any pipeline/deployment activity refreshes the dashboard immediately —
    # the 5s poll stays as fallback (FR-008).
    socket =
      socket
      |> assign_agents_data()
      |> assign(last_updated: DateTime.utc_now())

    {:noreply, socket}
  end

  @impl true
  def handle_event("test_fire", %{"agent" => agent, "payload" => payload}, socket) do
    # Route through the NORMAL trigger dispatch path (FR-009): registry gating
    # and manifest trigger checks apply exactly as for a real message trigger.
    result = AgentOS.TriggerGateway.submit_sync({:message, agent, payload})

    label =
      case result do
        {:fired, agents} -> "fired: #{Enum.join(agents, ", ")}"
        {:rejected, reason} -> "rejected: #{reason}"
        other -> inspect(other)
      end

    socket =
      socket
      |> assign(fire_result: {agent, label})
      |> assign_agents_data()
      |> assign(last_updated: DateTime.utc_now())

    {:noreply, socket}
  end

  # --- Helper functions ---

  defp schedule_tick do
    Process.send_after(self(), :tick, 5000)
  end

  # Reads the durable deployment record for an agent, tolerating a store that
  # is not running (e.g. minimal test trees).
  defp fetch_deployment(agent_name) do
    DeploymentRegistry.get(agent_name)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Deployment badge helpers: state comes from the registry, not from the mere
  # existence of a manifest file (FR-008).
  defp deployed_active?(%AgentOS.DeploymentRecord{active: true}), do: true
  defp deployed_active?(_), do: false

  defp deployment_status_class(%AgentOS.DeploymentRecord{active: true}), do: "active"
  defp deployment_status_class(%AgentOS.DeploymentRecord{active: false}), do: "inactive"
  defp deployment_status_class(_), do: "undeployed"

  defp deployment_status_label(%AgentOS.DeploymentRecord{active: true}), do: "deployed (active)"

  defp deployment_status_label(%AgentOS.DeploymentRecord{active: false}),
    do: "deployed (inactive)"

  defp deployment_status_label(_), do: "not deployed"

  # True when the manifest declares a message trigger (atom or string keys).
  defp has_message_trigger?(triggers) when is_list(triggers) do
    Enum.any?(triggers, fn
      %{type: :message} -> true
      %{"type" => "message"} -> true
      _ -> false
    end)
  end

  defp has_message_trigger?(_), do: false

  defp assign_agents_data(socket) do
    # Scan manifests/*.md for all agents
    manifest_paths = Path.wildcard("manifests/*.md")

    agents_data =
      Enum.reduce(manifest_paths, [], fn path, acc ->
        # Load inventory data using structured accessor
        case Inventory.data(manifest_path: path) do
          {:ok, data} ->
            # Get run records for this agent
            # Since RunLog.read_records parses the global run log file, read them here
            recent_runs = RunLog.read_records("data/run_log.md", window: 5)

            # Build final map: run trace + durable deployment state (FR-008).
            agent_map =
              data
              |> Map.put(:recent_runs, recent_runs)
              |> Map.put(:deployment, fetch_deployment(data.agent_name))

            [agent_map | acc]

          {:error, _reason} ->
            acc
        end
      end)
      |> Enum.sort_by(& &1.agent_name)

    assign(socket, agents_data: agents_data)
  end

  # Formatting micro-dollars to USD ($x.xxxxxx)
  defp format_dollars(micro_dollars) do
    dollars = micro_dollars / 1_000_000
    "$" <> :erlang.float_to_binary(dollars, [:compact, decimals: 6])
  end

  # CSS class mapping for provenance status
  defp provenance_status_class(nil), do: "unknown"
  defp provenance_status_class(prov), do: to_string(prov.status)

  # Text label mapping for provenance status
  defp provenance_status_label(nil), do: "Waiting for your approval"
  defp provenance_status_label(%{status: :reviewed_human}), do: "You approved this agent"

  defp provenance_status_label(%{status: :skipped_in_envelope}),
    do: "Auto-approved (within pre-set limits)"

  defp provenance_status_label(%{status: :dangerously_skipped}),
    do: "Approval was skipped — not safe"

  defp provenance_status_label(%{status: :failed, failure_reason: reason}) do
    reason_str =
      case reason do
        :judge_failed -> "failed the code check"
        :security_review_failed -> "failed the security check"
        :both_failed -> "failed the code and security checks"
        :missing_verdict -> "checks incomplete"
        :stale_verdict -> "checks incomplete"
        _ -> "failed a check"
      end

    "Blocked — #{reason_str}"
  end

  defp provenance_status_label(prov), do: to_string(prov.status)

  # CSS class mapping for judge status
  defp judge_status_class(nil), do: "unrun"
  defp judge_status_class(entry), do: to_string(entry.status)

  # Text label mapping for judge status
  defp judge_status_label(nil), do: "not run yet"

  defp judge_status_label(entry) do
    case Map.get(entry, :status) do
      :pass -> "pass"
      :fail -> "fail"
      :error -> "error"
      other -> to_string(other)
    end
  end

  # CSS class mapping for security review status
  defp security_status_class(nil), do: "unrun"
  defp security_status_class(entry), do: to_string(entry.status)

  # Text label mapping for security review status
  defp security_status_label(nil), do: "not run yet"

  defp security_status_label(entry) do
    case Map.get(entry, :status) do
      :pass -> "pass"
      :fail -> "fail"
      :error -> "error"
      other -> to_string(other)
    end
  end

  # CSS class mapping for conformance status
  defp conformance_status_class(nil), do: "insufficient"
  defp conformance_status_class(entry), do: to_string(entry.status)

  # Text label mapping for conformance status
  defp conformance_status_label(nil), do: "not enough runs yet"

  defp conformance_status_label(entry) do
    case Map.get(entry, :status) do
      :clean -> "clean"
      :flagged -> "flagged"
      :insufficient_data -> "not enough runs yet"
      other -> to_string(other)
    end
  end

  # Spend alert CSS class
  defp spend_class(spent, cap) do
    cond do
      spent >= cap -> "spend-breached-box"
      spent >= cap * 0.8 -> "spend-warning-box"
      true -> "spend-normal-box"
    end
  end

  # Conformance flag axis label mapping
  defp flag_axis(type) do
    case type do
      :quiet -> "health"
      :sick -> "health"
      :denied_approval -> "trust"
      :gate_breach -> "trust"
    end
  end

  # Formatting triggers to human-readable format
  defp format_triggers(triggers) when is_list(triggers) do
    Enum.map(triggers, fn
      %{"type" => "time", "at" => at} ->
        "Time: #{at}"

      %{type: :time, at: at} ->
        "Time: #{at}"

      %{"type" => "message"} ->
        "Message"

      %{type: :message} ->
        "Message"

      %{"type" => "event", "name" => name} ->
        "Event: #{name}"

      %{type: :event, name: name} ->
        "Event: #{name}"

      other when is_map(other) ->
        type = Map.get(other, :type) || Map.get(other, "type")
        name = Map.get(other, :name) || Map.get(other, "name")
        at = Map.get(other, :at) || Map.get(other, "at")

        cond do
          type in [:time, "time"] -> "Time: #{at}"
          type in [:message, "message"] -> "Message"
          type in [:event, "event"] -> "Event: #{name}"
          true -> inspect(other)
        end

      other ->
        inspect(other)
    end)
  end

  defp format_triggers(_), do: []
end
