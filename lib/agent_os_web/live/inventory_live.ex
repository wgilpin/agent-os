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
      |> assign(
        last_updated: DateTime.utc_now(),
        fire_result: nil,
        # agent_name whose edit panel is expanded (nil = all collapsed).
        editing: nil,
        # Draft state for the open edit panel: trigger rows (string-keyed form shape) and
        # the cap field, kept in sync via phx-change so re-renders don't lose typed input.
        trigger_draft: [],
        cap_draft: nil,
        # last lifecycle-action error, rendered as an inline banner (no flash layout exists).
        action_error: nil,
        # agent whose manual run was just started (inline confirmation note).
        run_started: nil,
        # agent whose "Re-run checks" was just triggered (inline confirmation note).
        rerun_started: nil,
        # agent_name with the delete confirmation open (nil = none). Delete is
        # two-step and fully server-rendered so it never depends on browser JS.
        confirm_delete: nil
      )

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

      <%= if @action_error do %>
        <div class="action-error-banner" role="alert">
          <strong>Couldn't do that:</strong> <%= @action_error %>
        </div>
      <% end %>

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

                  <%= if agent.last_rerun do %>
                    <!-- Last "Re-run checks" outcome (spec 043, FR-007): stays visible after the
                         fact; the failing check + reason surface here for a red/incomplete run. -->
                    <div class="meta-row rerun-history-row">
                      <strong>Last checks re-run:</strong>
                      <span class={"badge badge-rerun-#{agent.last_rerun.outcome}"}>
                        <%= rerun_outcome_label(agent.last_rerun.outcome) %>
                      </span>
                      <span class="rerun-when" title={agent.last_rerun.finished_at}>
                        <%= rerun_when(agent.last_rerun.finished_at) %>
                      </span>
                      <%= if agent.last_rerun.reason do %>
                        <span class="rerun-reason">— <%= agent.last_rerun.reason %></span>
                      <% end %>
                    </div>
                  <% end %>

                  <!-- Lifecycle controls (spec 042): pause/resume/delete + edit panel.
                       All mutations route through AgentOS.AgentLifecycle; the view stays thin. -->
                  <div class="meta-row lifecycle-row">
                    <strong>Controls:</strong>
                    <div class="lifecycle-buttons">
                      <%= if deployed_active?(agent.deployment) do %>
                        <button
                          type="button"
                          class="btn-secondary btn-run-now"
                          phx-click="run_now"
                          phx-value-agent={agent.agent_name}
                        >
                          Run now
                        </button>
                        <button
                          type="button"
                          class="btn-secondary btn-pause"
                          phx-click="pause"
                          phx-value-agent={agent.agent_name}
                        >
                          Pause
                        </button>
                      <% end %>
                      <%= if paused?(agent.deployment) do %>
                        <button
                          type="button"
                          class="btn-secondary btn-resume"
                          phx-click="resume"
                          phx-value-agent={agent.agent_name}
                        >
                          Resume
                        </button>
                      <% end %>
                      <%= if agent.rerun_available? do %>
                        <!-- Re-run checks (spec 043): re-examine existing code + manifest with the
                             same compliance/security checks. Only for agents that HAVE code and
                             whose checks are not already green for that code. -->
                        <button
                          type="button"
                          class="btn-secondary btn-rerun-checks"
                          phx-click="rerun_checks"
                          phx-value-agent={agent.agent_name}
                        >
                          Re-run checks
                        </button>
                      <% end %>
                      <button
                        type="button"
                        class="btn-secondary btn-edit"
                        phx-click="toggle_edit"
                        phx-value-agent={agent.agent_name}
                      >
                        <%= if @editing == agent.agent_name, do: "Close", else: "Edit" %>
                      </button>
                      <button
                        type="button"
                        class="btn-danger btn-delete"
                        phx-click="request_delete"
                        phx-value-agent={agent.agent_name}
                      >
                        Delete
                      </button>
                    </div>
                    <%= if @confirm_delete == agent.agent_name do %>
                      <!-- Server-rendered confirmation (no JS): delete only fires from here. -->
                      <div class="delete-confirm" role="alertdialog">
                        <span class="delete-confirm-text">
                          Permanently delete "<%= AgentOSWeb.HumanText.humanize_name(agent.agent_name) %>"?
                          This removes its code, its manifest, and all of its runtime state.
                          This cannot be undone.
                        </span>
                        <button
                          type="button"
                          class="btn-danger btn-confirm-delete"
                          phx-click="delete"
                          phx-value-agent={agent.agent_name}
                        >
                          Yes, delete permanently
                        </button>
                        <button type="button" class="btn-secondary btn-cancel-delete" phx-click="cancel_delete">
                          Cancel
                        </button>
                      </div>
                    <% end %>
                    <%= if @run_started == agent.agent_name do %>
                      <span class="run-started-note">
                        Run started — it will show under recent executions shortly.
                      </span>
                    <% end %>
                    <%= if @rerun_started == agent.agent_name do %>
                      <span class="rerun-started-note">
                        Checks re-running — the Code check and Safety check above will update shortly.
                      </span>
                    <% end %>
                    <%= if awaiting_approval?(agent) do %>
                      <span class="deploy-hint">
                        To deploy and run this agent,
                        <.link navigate="/consent" class="deploy-hint-link">approve it on the consent page</.link>.
                      </span>
                    <% end %>
                  </div>

                  <%= if @editing == agent.agent_name do %>
                    <!-- Draft-based editor (no JS): phx-change keeps @trigger_draft in sync so
                         add/remove/retype re-renders preserve what the user has typed. -->
                    <form class="edit-settings-panel" phx-submit="update_settings" phx-change="draft_change">
                      <input type="hidden" name="agent" value={agent.agent_name} />
                      <div class="edit-field">
                        <label for={"cap-#{agent.agent_name}"}>Daily spend cap (US$)</label>
                        <input
                          type="number"
                          id={"cap-#{agent.agent_name}"}
                          name="spend_cap"
                          min="0"
                          step="0.000001"
                          value={@cap_draft}
                        />
                      </div>

                      <div class="edit-triggers">
                        <span class="edit-triggers-title">Runs when…</span>
                        <%= if Enum.empty?(@trigger_draft) do %>
                          <p class="edit-triggers-empty">
                            No triggers — this agent will never run until you add one.
                          </p>
                        <% end %>
                        <%= for {row, idx} <- Enum.with_index(@trigger_draft) do %>
                          <div class="trigger-edit-row">
                            <select name={"triggers[#{idx}][type]"} id={"trigger-type-#{agent.agent_name}-#{idx}"}>
                              <option value="time" selected={row["type"] == "time"}>Daily at a time</option>
                              <option value="startup" selected={row["type"] == "startup"}>On startup</option>
                              <option value="event" selected={row["type"] == "event"}>On an event</option>
                              <option value="message" selected={row["type"] == "message"}>On a message</option>
                            </select>
                            <%= if row["type"] == "time" do %>
                              <input
                                type="text"
                                name={"triggers[#{idx}][at]"}
                                value={row["at"]}
                                pattern="[0-2]?[0-9]:[0-5][0-9]"
                                placeholder="HH:MM"
                                class="trigger-param-input"
                              />
                            <% end %>
                            <%= if row["type"] == "event" do %>
                              <input
                                type="text"
                                name={"triggers[#{idx}][name]"}
                                value={row["name"]}
                                placeholder="event name"
                                class="trigger-param-input"
                              />
                            <% end %>
                            <button
                              type="button"
                              class="btn-secondary btn-remove-trigger"
                              phx-click="remove_trigger"
                              phx-value-index={idx}
                            >
                              Remove
                            </button>
                          </div>
                        <% end %>
                        <button type="button" class="btn-secondary btn-add-trigger" phx-click="add_trigger">
                          Add trigger
                        </button>
                      </div>

                      <button type="submit" class="btn-primary">Save settings</button>
                    </form>
                  <% end %>
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
                            <th>When</th>
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
                              <td>
                                <span class="trigger-code" title={run.trigger}>
                                  <%= AgentOSWeb.HumanText.humanize_trigger(run.trigger) %>
                                </span>
                              </td>
                              <td class="numeric-cell"><%= run.items_in %> / <%= run.items_dropped %></td>
                              <td class="note-cell" title={run.note}>
                                <%= AgentOSWeb.HumanText.humanize_run_note(run.note) %>
                                <%= if run.breached_count > 0, do: " (#{run.breached_count} blocked by limits)" %>
                              </td>
                              <td class="numeric-cell" title={run.timestamp}>
                                <%= run_time(run.timestamp) %>
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
  def handle_info({:pipeline_progress, %ProgressEvent{} = event}, socket) do
    # Any pipeline/deployment activity refreshes the dashboard immediately —
    # the 5s poll stays as fallback (FR-008).
    socket =
      socket
      |> assign_agents_data()
      |> assign(last_updated: DateTime.utc_now())
      |> maybe_clear_rerun_note(event)

    {:noreply, socket}
  end

  # A rerun's terminal event carries stage :pipeline (its per-check events are
  # :judge/:security_review). Clear the "Checks re-running" note then — the
  # refreshed agents_data shows the persisted outcome line in its place.
  defp maybe_clear_rerun_note(socket, %ProgressEvent{stage: :pipeline, agent_name: agent}) do
    if socket.assigns.rerun_started == agent do
      assign(socket, rerun_started: nil)
    else
      socket
    end
  end

  defp maybe_clear_rerun_note(socket, _event), do: socket

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

  @impl true
  def handle_event("run_now", %{"agent" => agent}, socket) do
    case AgentOS.AgentLifecycle.run_now(agent) do
      :ok ->
        socket =
          socket
          |> assign(action_error: nil, run_started: agent)
          |> refresh_after_action(agent)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, action_error: error_text(reason))}
    end
  end

  @impl true
  def handle_event("rerun_checks", %{"agent" => agent}, socket) do
    # Recovery path (spec 043): re-run the compliance + security checks against the agent's
    # EXISTING code. Progress and the outcome arrive over the pipeline firehose this view
    # already subscribes to; here we just confirm start or surface a refusal.
    case AgentOS.Pipeline.Rerun.start(agent) do
      {:ok, _run_id} ->
        socket =
          socket
          |> assign(action_error: nil, run_started: nil, rerun_started: agent)
          |> refresh_after_action(agent)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, action_error: rerun_error_text(reason))}
    end
  end

  @impl true
  def handle_event("pause", %{"agent" => agent}, socket) do
    {:noreply, apply_lifecycle(socket, agent, fn -> AgentOS.AgentLifecycle.pause(agent) end)}
  end

  @impl true
  def handle_event("resume", %{"agent" => agent}, socket) do
    {:noreply, apply_lifecycle(socket, agent, fn -> AgentOS.AgentLifecycle.resume(agent) end)}
  end

  @impl true
  def handle_event("request_delete", %{"agent" => agent}, socket) do
    {:noreply, assign(socket, confirm_delete: agent)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: nil)}
  end

  @impl true
  def handle_event("delete", %{"agent" => agent}, socket) do
    # Only reachable from the open confirmation for this agent — a stale or
    # forged click without the confirmation open is ignored.
    if socket.assigns.confirm_delete == agent do
      # delete/1 always returns :ok (idempotent, tolerant of partial state).
      socket = apply_lifecycle(socket, agent, fn -> AgentOS.AgentLifecycle.delete(agent) end)
      # Collapse the edit panel if it was open for the now-gone agent.
      {:noreply, assign(socket, editing: nil, confirm_delete: nil)}
    else
      {:noreply, assign(socket, confirm_delete: nil)}
    end
  end

  @impl true
  def handle_event("toggle_edit", %{"agent" => agent}, socket) do
    # Pure UI toggle (no JS): open this agent's panel, or close it if already open.
    # Opening seeds the draft (trigger rows + cap) from the agent's current data so the
    # form edits a copy; nothing persists until "Save settings".
    if socket.assigns.editing == agent do
      {:noreply, assign(socket, editing: nil, action_error: nil)}
    else
      agent_data = Enum.find(socket.assigns.agents_data, &(&1.agent_name == agent))

      {:noreply,
       assign(socket,
         editing: agent,
         action_error: nil,
         trigger_draft: draft_rows(agent_data && agent_data.triggers),
         cap_draft: cap_dollars(agent_data && agent_data.spend_cap)
       )}
    end
  end

  @impl true
  def handle_event("draft_change", params, socket) do
    # Keep the draft in sync with every keystroke/select change so add/remove re-renders
    # never lose what the user has typed (the form is fully server-driven, no JS).
    {:noreply,
     assign(socket,
       trigger_draft: draft_from_params(params),
       cap_draft: Map.get(params, "spend_cap", socket.assigns.cap_draft)
     )}
  end

  @impl true
  def handle_event("add_trigger", _params, socket) do
    # Append a fresh row; "time" is the most common intent so it is the default type.
    draft = socket.assigns.trigger_draft ++ [%{"type" => "time", "at" => "", "name" => ""}]
    {:noreply, assign(socket, trigger_draft: draft)}
  end

  @impl true
  def handle_event("remove_trigger", %{"index" => index}, socket) do
    draft = List.delete_at(socket.assigns.trigger_draft, String.to_integer(index))
    {:noreply, assign(socket, trigger_draft: draft)}
  end

  @impl true
  def handle_event("update_settings", params, socket) do
    %{"agent" => agent} = params

    # Untouched rows (added but never filled in) are dropped rather than failing the save;
    # partially-filled rows still validate so typos surface instead of vanishing.
    triggers = params |> draft_from_params() |> Enum.reject(&blank_trigger_row?/1)

    with :ok <- apply_cap(agent, Map.get(params, "spend_cap")),
         :ok <- AgentOS.AgentLifecycle.update_triggers(agent, triggers) do
      socket =
        socket
        |> assign(editing: nil, action_error: nil, trigger_draft: [], cap_draft: nil)
        |> refresh_after_action(agent)

      {:noreply, socket}
    else
      {:error, reason} ->
        {:noreply, assign(socket, action_error: error_text(reason))}
    end
  end

  # --- Helper functions ---

  # Runs a lifecycle action, then either records the error or refreshes + broadcasts on success.
  defp apply_lifecycle(socket, agent, fun) do
    case fun.() do
      :ok ->
        socket
        |> assign(action_error: nil, run_started: nil)
        |> refresh_after_action(agent)

      {:error, reason} ->
        assign(socket, action_error: error_text(reason))
    end
  end

  # Refreshes this session's data and broadcasts so other open inventory sessions converge
  # (FR-012). Reuses the pipeline firehose the view already subscribes to.
  defp refresh_after_action(socket, agent) do
    ProgressEvent.new("lifecycle:#{agent}", agent, :deploy, :finished, :lifecycle)
    |> ProgressEvent.broadcast()

    socket
    |> assign_agents_data()
    |> assign(last_updated: DateTime.utc_now())
  end

  # Parses the dollar cap from the form and applies it; a blank field skips the cap update.
  defp apply_cap(_agent, nil), do: :ok
  defp apply_cap(_agent, ""), do: :ok

  defp apply_cap(agent, dollars_str) do
    case Float.parse(dollars_str) do
      {dollars, _rest} -> AgentOS.AgentLifecycle.update_spend_cap(agent, dollars)
      :error -> {:error, :invalid_cap}
    end
  end

  # Human-readable copy for lifecycle-action failures.
  defp error_text(:not_deployed),
    do: "that agent isn't deployed, so it can't be paused or resumed."

  defp error_text(:system_agent),
    do: "that agent belongs to the substrate — it can't be changed from here."

  defp error_text(:not_active),
    do: "the agent must be deployed and active to run — resume or deploy it first."

  defp error_text(:code_missing),
    do:
      "this agent has a manifest but no generated code, so it can't run. " <>
        "Delete it, or create it again from the Create agent page."

  defp error_text(:manifest_missing),
    do: "the agent's manifest file is missing — it can't be resumed."

  defp error_text(:invalid_cap), do: "the spend cap must be a number greater than zero."

  defp error_text({:invalid_time, at}),
    do: "\"#{at}\" isn't a valid time — use HH:MM (00:00–23:59)."

  defp error_text(:invalid_event_name), do: "event triggers need a (non-empty) event name."

  defp error_text(:duplicate_triggers),
    do: "two of the triggers are identical — remove one of them."

  defp error_text({:unknown_trigger_type, type}),
    do: "\"#{inspect(type)}\" isn't a recognised trigger type."

  defp error_text(other), do: "something went wrong (#{inspect(other)})."

  # Human-readable copy for a refused "Re-run checks" request (spec 043).
  defp rerun_error_text(:busy),
    do:
      "a check is already running for this agent — wait for it to finish before starting another."

  defp rerun_error_text(:code_missing),
    do:
      "this agent has no generated code, so there's nothing to check. " <>
        "Delete it, or create it again from the Create agent page."

  defp rerun_error_text(:system_agent),
    do: "that agent belongs to the substrate — its checks can't be re-run from here."

  defp rerun_error_text(:manifest_missing),
    do: "this agent's manifest file is missing, so its checks can't be re-run."

  defp rerun_error_text(:checks_green),
    do: "this agent's checks already pass for its current code — there's nothing to re-run."

  defp rerun_error_text(other), do: "couldn't start the re-run (#{inspect(other)})."

  # Label for a persisted re-run outcome.
  defp rerun_outcome_label(:passed), do: "passed"
  defp rerun_outcome_label(:failed), do: "failed"
  defp rerun_outcome_label(:incomplete), do: "did not complete"
  defp rerun_outcome_label(other), do: to_string(other)

  # Formats a re-run's finish DateTime for the card ("2026-07-10 12:00"); blank if in flight.
  defp rerun_when(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp rerun_when(_), do: ""

  # Deployment-state predicates for the lifecycle controls.
  defp paused?(%AgentOS.DeploymentRecord{active: false}), do: true
  defp paused?(_), do: false

  # Any undeployed agent: the consent page is always the path to deploying it (approve
  # completes the deploy even when no pending action exists).
  defp awaiting_approval?(agent), do: is_nil(agent.deployment)

  # The agent's spend cap rendered in dollars for the edit form (micro-dollars / 1_000_000).
  defp cap_dollars(micro_dollars) when is_number(micro_dollars) do
    :erlang.float_to_binary(micro_dollars / 1_000_000, [:compact, decimals: 6])
  end

  defp cap_dollars(_), do: "0"

  # Converts manifest triggers (atom or string keys) into string-keyed draft rows for the
  # edit form.
  defp draft_rows(triggers) when is_list(triggers) do
    Enum.map(triggers, fn t ->
      type = Map.get(t, :type) || Map.get(t, "type")

      %{
        "type" => to_string(type),
        "at" => Map.get(t, :at) || Map.get(t, "at") || "",
        "name" => Map.get(t, :name) || Map.get(t, "name") || ""
      }
    end)
  end

  defp draft_rows(_), do: []

  # A row whose required field was never filled in: an empty shell, not user intent.
  # Startup/message rows have no fields, so they are always complete.
  defp blank_trigger_row?(%{"type" => "time"} = row),
    do: String.trim(row["at"] || "") == ""

  defp blank_trigger_row?(%{"type" => "event"} = row),
    do: String.trim(row["name"] || "") == ""

  defp blank_trigger_row?(_row), do: false

  # Rebuilds the ordered draft rows from indexed form params ("triggers" => %{"0" => row, …}).
  defp draft_from_params(params) do
    params
    |> Map.get("triggers", %{})
    |> Enum.sort_by(fn {idx, _row} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, row} -> row end)
  end

  # "2026-07-09T16:22:33.745Z" → "2026-07-09 16:22" (raw ISO stays in the tooltip).
  defp run_time(nil), do: ""

  defp run_time(iso) do
    iso |> String.slice(0, 16) |> String.replace("T", " ")
  end

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

  # Reads the latest "Re-run checks" record for an agent, tolerating an absent store.
  defp fetch_last_rerun(agent_name) do
    AgentOS.StateStore.snapshot("check_reruns")[agent_name]
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
    # Scan manifests/*.md for all agents. Substrate-owned agents (e.g. discovery) are
    # hidden: they are not the user's to manage, and AgentLifecycle refuses them anyway.
    manifest_paths =
      "manifests/*.md"
      |> Path.wildcard()
      |> Enum.reject(&AgentOS.AgentLifecycle.system_agent?(Path.basename(&1, ".md")))

    # One read of the global log; each card gets only ITS runs, newest first.
    # Legacy lines without an agent= field are attributed to no card.
    all_runs = RunLog.read_records(RunLog.default_path())

    agents_data =
      Enum.reduce(manifest_paths, [], fn path, acc ->
        # Load inventory data using structured accessor
        case Inventory.data(manifest_path: path) do
          {:ok, data} ->
            recent_runs =
              all_runs
              |> Enum.filter(&(&1.agent == data.agent_name))
              |> Enum.take(-5)
              |> Enum.reverse()

            # Build final map: run trace + durable deployment state (FR-008).
            agent_map =
              data
              |> Map.put(:recent_runs, recent_runs)
              |> Map.put(:deployment, fetch_deployment(data.agent_name))
              # Re-run eligibility (spec 043): only agents WITH generated code get the button.
              |> Map.put(
                :code_present?,
                File.exists?(Path.join(["agents", data.agent_name, "main.py"]))
              )
              # A re-run is a recovery path: hide it when both checks already pass for
              # the current code (the gate would open; a re-run would change nothing).
              |> Map.put(
                :rerun_available?,
                AgentOS.Pipeline.Rerun.eligible?(data.agent_name) == :ok
              )
              |> Map.put(:last_rerun, fetch_last_rerun(data.agent_name))

            [agent_map | acc]

          {:error, _reason} ->
            acc
        end
      end)

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
          type in [:startup, "startup"] -> "On startup"
          # Unknown-but-typed triggers get a readable label, never raw Elixir.
          not is_nil(type) -> type |> to_string() |> String.capitalize()
          true -> inspect(other)
        end

      other ->
        inspect(other)
    end)
  end

  defp format_triggers(_), do: []
end
