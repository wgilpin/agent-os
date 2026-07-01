# Contracts: Standing Inventory Dashboard

## Endpoint Route Mapping
* **Path**: `/inventory`
* **Route definition**: `live "/inventory", InventoryLive, :index` inside `lib/agent_os_web/router.ex`
* **Controller**: `AgentOSWeb.InventoryLive`

---

## UI Layout & Structure

The dashboard is read-only and displays information in a clear grid card format.

### HTML Structure

```html
<div class="inventory-dashboard">
  <header class="dashboard-header">
    <h1>Agent OS Standing Inventory</h1>
    <span class="last-updated">Last updated: <%= DateTime.to_string(@last_updated) %></span>
  </header>

  <div class="agent-grid">
    <%= for agent <- @agents_data do %>
      <div class="agent-card" id={"agent-card-#{agent.agent_name}"}>
        <!-- Roster Panel -->
        <section class="panel roster-panel">
          <h2>Roster: <%= agent.agent_name %></h2>
          <p class="purpose"><strong>Purpose:</strong> <%= agent.purpose %></p>
          <p class="triggers"><strong>Triggers:</strong> <%= inspect(agent.triggers) %></p>
          <p class="owner"><strong>Owner/Supervision:</strong> <%= agent.owner %> / <%= agent.supervision %></p>
          
          <div class="deploy-provenance">
            <strong>Deploy Provenance:</strong>
            <span class={"badge badge-provenance-#{provenance_status(agent.provenance)}"}>
              <%= provenance_label(agent.provenance) %>
            </span>
          </div>

          <div class="status-line">
            <strong>Combined Status:</strong>
            <span class={"badge badge-judge-#{judge_status(agent.judge)}"}>Judge: <%= judge_label(agent.judge) %></span>
            <span class={"badge badge-security-#{security_status(agent.security_review)}"}>Security: <%= security_label(agent.security_review) %></span>
            <span class={"badge badge-conformance-#{conformance_status(agent.conformance)}"}>Conformance: <%= conformance_label(agent.conformance) %></span>
          </div>
        </section>

        <!-- Spend Panel -->
        <section class="panel spend-panel">
          <h2>Spend Status</h2>
          <div class={"spend-amount #{spend_alert_class(agent.spent, agent.spend_cap)}"}>
            <span class="spent"><%= format_dollars(agent.spent) %></span>
            <span class="separator">/</span>
            <span class="cap"><%= format_dollars(agent.spend_cap) %></span>
            <span class="window">per <%= agent.spend_window %></span>
          </div>
          <%= if agent.spent >= agent.spend_cap do %>
            <div class="spend-alert-msg error-msg">BREACH: Agent has exceeded spend cap!</div>
          <% else %>
            <%= if agent.spent >= agent.spend_cap * 0.8 do %>
              <div class="spend-alert-msg warning-msg">WARNING: Agent spend is near cap (>= 80%).</div>
            <% end %>
          <% end %>
        </section>

        <!-- Audit Log Panel -->
        <section class="panel audit-panel">
          <h2>Audit Log & Conformance</h2>
          
          <div class="recent-runs">
            <h3>Recent Runs (RunRecords)</h3>
            <%= if Enum.empty?(agent.recent_runs) do %>
              <p>No runs recorded.</p>
            <% else %>
              <table class="run-records-table">
                <thead>
                  <tr>
                    <th>Status</th>
                    <th>Actions</th>
                    <th>Trigger</th>
                    <th>In / Dropped</th>
                    <th>Note</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for run <- agent.recent_runs do %>
                    <tr class={"run-status-#{run.status}"}>
                      <td><span class="badge"><%= run.status %></span></td>
                      <td><%= run.actions %></td>
                      <td><%= run.trigger %></td>
                      <td><%= run.items_in %> / <%= run.items_dropped %></td>
                      <td><%= run.note %></td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>

          <%= if agent.conformance && agent.conformance.status == :flagged do %>
            <div class="conformance-flags">
              <h3>Conformance Flags</h3>
              <ul class="flags-list">
                <%= for flag <- agent.conformance.flags do %>
                  <li class={"flag-item flag-severity-#{flag.severity}"}>
                    <span class="flag-axis">[<%= flag_axis(flag.type) %>]</span>
                    <span class="flag-type"><%= String.replace(to_string(flag.type), "_", "-") %></span> — <%= flag.description %>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>

          <%= if not Enum.empty?(agent.pending_approvals) do %>
            <div class="pending-approvals-section">
              <h3>Pending Approvals</h3>
              <ul class="approvals-list">
                <%= for app <- agent.pending_approvals do %>
                  <li>
                    <span class="ref"><%= app.ref %></span>: <%= app.action.type %>
                    <%= if app.action.recipient, do: " → " <> app.action.recipient %>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>

          <div class="capabilities-list">
            <h3>Capabilities</h3>
            <ul class="caps-list">
              <%= for entry <- agent.capabilities do %>
                <li class={"cap-item danger-badge-#{entry.danger}"}>
                  <span class="cap-badge"><%= String.upcase(to_string(entry.danger)) %></span>
                  <%= entry.phrase %>
                  <%= if entry.recipients || entry.methods do %>
                    <span class="cap-scope">(recipients: <%= inspect(entry.recipients) %>, methods: <%= inspect(entry.methods) %>)</span>
                  <% end %>
                </li>
              <% end %>
            </ul>
          </div>
        </section>
      </div>
    <% end %>
  </div>
</div>
```
