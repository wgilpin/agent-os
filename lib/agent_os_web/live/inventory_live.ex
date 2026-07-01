defmodule AgentOSWeb.InventoryLive do
  @moduledoc """
  Phoenix LiveView screen rendering the standing inventory dashboard.
  Lists all provisioned agents with their roster, spend status, capabilities,
  and legible run trace audit log.
  """
  use Phoenix.LiveView

  alias AgentOS.Inventory
  alias AgentOS.RunLog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_tick()
    end

    socket =
      socket
      |> assign_agents_data()
      |> assign(last_updated: DateTime.utc_now())

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
                  <h2>Roster: <span class="agent-name-highlight"><%= agent.agent_name %></span></h2>
                </div>
                <div class="metadata-content">
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
                    <strong>Deploy Provenance:</strong>
                    <span class={"badge badge-provenance badge-provenance-#{provenance_status_class(agent.provenance)}"}>
                      <%= provenance_status_label(agent.provenance) %>
                    </span>
                  </div>

                  <div class="meta-row combined-status-row">
                    <strong>Combined Status:</strong>
                    <div class="badge-group">
                      <span class={"badge badge-judge-#{judge_status_class(agent.judge)}"}>
                        Judge: <%= judge_status_label(agent.judge) %>
                      </span>
                      <span class={"badge badge-security-#{security_status_class(agent.security_review)}"}>
                        Security: <%= security_status_label(agent.security_review) %>
                      </span>
                      <span class={"badge badge-conformance-#{conformance_status_class(agent.conformance)}"}>
                        Conformance: <%= conformance_status_label(agent.conformance) %>
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

                <!-- Capabilities -->
                <div class="capabilities-section">
                  <h3>Capabilities</h3>
                  <div class="capabilities-grid">
                    <%= for entry <- agent.capabilities do %>
                      <div class={"cap-item-box danger-badge-#{entry.danger}"}>
                        <div class="cap-meta">
                          <span class="cap-connector"><%= entry.phrase %></span>
                          <span class={"danger-tag danger-tag-#{entry.danger}"}><%= String.upcase(to_string(entry.danger)) %></span>
                        </div>
                        <%= if entry.recipients || entry.methods do %>
                          <div class="cap-scopes">
                            <%= if entry.recipients do %>
                              <span class="scope-group"><span class="scope-key">recipients:</span> <span class="scope-val"><%= Enum.join(entry.recipients, ", ") %></span></span>
                            <% end %>
                            <%= if entry.recipients && entry.methods, do: " · " %>
                            <%= if entry.methods do %>
                              <span class="scope-group"><span class="scope-key">methods:</span> <span class="scope-val"><%= Enum.join(entry.methods, ", ") %></span></span>
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

  # --- Helper functions ---

  defp schedule_tick do
    Process.send_after(self(), :tick, 5000)
  end

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

            # Build final map
            agent_map = Map.put(data, :recent_runs, recent_runs)
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
  defp provenance_status_label(nil), do: "unknown"
  defp provenance_status_label(%{status: :reviewed_human}), do: "reviewed=human"
  defp provenance_status_label(%{status: :skipped_in_envelope}), do: "skipped-in-envelope"
  defp provenance_status_label(%{status: :dangerously_skipped}), do: "dangerously-skipped"

  defp provenance_status_label(%{status: :failed, failure_reason: reason}) do
    reason_str =
      case reason do
        :judge_failed -> "judge"
        :security_review_failed -> "security-review"
        :both_failed -> "both"
        :missing_verdict -> "missing/stale verdict"
        :stale_verdict -> "missing/stale verdict"
        _ -> "unknown"
      end

    "failed (check: #{reason_str})"
  end

  defp provenance_status_label(prov), do: to_string(prov.status)

  # CSS class mapping for judge status
  defp judge_status_class(nil), do: "unrun"
  defp judge_status_class(entry), do: to_string(entry.status)

  # Text label mapping for judge status
  defp judge_status_label(nil), do: "unrun"

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
  defp security_status_label(nil), do: "unrun"

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
  defp conformance_status_label(nil), do: "insufficient data"

  defp conformance_status_label(entry) do
    case Map.get(entry, :status) do
      :clean -> "clean"
      :flagged -> "flagged"
      :insufficient_data -> "insufficient data"
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
