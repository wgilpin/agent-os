defmodule AgentOSWeb.ElicitationLive do
  use Phoenix.LiveView

  alias AgentOS.ElicitationSession

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       session_pid: nil,
       session: nil,
       creep_warning: nil,
       show_confirm: false,
       success_message: nil,
       local_prompt: nil,
       purpose_input: "",
       message_input: ""
     )}
  end

  @impl true
  def terminate(_reason, socket) do
    if pid = socket.assigns[:session_pid] do
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="workspace-wrapper">
      <%= if @success_message do %>
        <div class="landing-container">
          <div class="landing-card">
            <div class="landing-logo">
              <svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
            </div>
            <h1>Specification Confirmed!</h1>
            <p><%= @success_message %></p>
            <button class="btn-primary" phx-click="reset_flow">Start New Elicitation</button>
          </div>
        </div>
      <% else %>
        <%= if is_nil(@session_pid) do %>
          <!-- Landing State -->
          <div class="landing-container">
            <div class="landing-card">
              <div class="landing-logo">
                <svg viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-2 10H7v-2h10v2z"/></svg>
              </div>
              <h1>Agent OS Elicitor</h1>
              <p>Define one agent with one clear purpose. In a single sentence — what do you want it to do?</p>

              <form class="landing-form" phx-submit="start_session">
                <textarea
                  name="purpose"
                  placeholder="e.g., Watch the customer reviews on my Shopify store and email me a short summary every Monday."
                  required
                ><%= @purpose_input %></textarea>
                <button type="submit" class="btn-primary">Start Elicitation Session</button>
              </form>
            </div>
          </div>
        <% else %>
          <!-- Split Workspace Layout -->
          <div class="workspace-container">
            <!-- Left Pane: Chat log & interaction -->
            <div class="chat-panel">
              <div class="chat-header">
                <div class="chat-title-group">
                  <div class="chat-logo">
                    <svg viewBox="0 0 24 24"><path d="M20 2H4c-1.1 0-1.99.9-1.99 2L2 22l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zM6 9h12v2H6V9zm8 5H6v-2h8v2zm4-6H6V6h12v2z"/></svg>
                  </div>
                  <div class="chat-title">
                    <h2>Elicitation Workspace</h2>
                    <span>Orchestrator turn loop active</span>
                  </div>
                </div>

                <div class="session-status">
                  <span class="status-dot"></span>
                  <%= if @show_confirm, do: "Confirming", else: "Active" %>
                </div>
              </div>

              <!-- Message History -->
              <div class="chat-messages" id="messages-box" phx-hook="ScrollToBottom">
                <%= for msg <- @session.transcript do %>
                  <div class={"message-row #{msg.role}"}>
                    <div class="message-bubble">
                      <div class="bubble-label"><%= msg.role %></div>
                      <div class="bubble-content"><%= msg.content %></div>
                    </div>
                  </div>
                <% end %>

                <%= if @local_prompt do %>
                  <div class="message-row assistant">
                    <div class="message-bubble">
                      <div class="bubble-label">assistant</div>
                      <div class="bubble-content"><%= @local_prompt %></div>
                    </div>
                  </div>
                <% end %>
              </div>

              <!-- KISS Check Warning -->
              <%= if @creep_warning do %>
                <div class="creep-warning-box">
                  <div class="creep-title">[KISS Check Warning]</div>
                  <div class="creep-content"><%= @creep_warning %></div>
                </div>
              <% end %>

              <!-- Bottom Input Bar -->
              <div class="chat-input-bar">
                <%= if @show_confirm do %>
                  <!-- Confirm / Refine controls -->
                  <div class="confirm-card">
                    <h3>Confirm Elicited Specification?</h3>
                    <p>Please review the proposed spec details in the sidebar before confirming.</p>
                    <div class="confirm-actions">
                      <button class="btn-confirm" phx-click="confirm_spec">Yes, Write Spec</button>
                      <button class="btn-refine" phx-click="refine_spec">No, Refine</button>
                    </div>
                  </div>
                <% else %>
                  <form class="input-form" phx-submit="submit_message">
                    <textarea
                      name="message"
                      placeholder="Type your reply..."
                      phx-keydown="submit_key"
                      required
                    ><%= @message_input %></textarea>
                    <button type="submit" class="btn-send">Send</button>
                  </form>

                  <div class="input-help-text">
                    <span>Enter to send · Shift+Enter for newline</span>
                    <span>turn <%= div(length(@session.transcript), 2) + 1 %></span>
                  </div>
                <% end %>
              </div>
            </div>

            <!-- Right Pane: Live Spec Sidebar -->
            <div class="spec-sidebar">
              <div class="sidebar-header">
                <h3>Live Spec</h3>
              </div>

              <div class="spec-card">
                <div class="spec-card-header">
                  <h4>Proposed Specification</h4>
                  <p>Fills in as the intent sharpens</p>
                </div>

                <%= if @session.spec_draft do %>
                  <div class="spec-section">
                    <div class="spec-label">Purpose</div>
                    <div class="spec-value">
                      <%= @session.spec_draft.purpose || "— pending" %>
                    </div>
                  </div>

                  <div class="spec-section">
                    <div class="spec-label">Capabilities</div>
                    <%= if Enum.any?(@session.spec_draft.capabilities) do %>
                      <div class="pill-container">
                        <%= for cap <- @session.spec_draft.capabilities do %>
                          <span class="pill"><%= cap %></span>
                        <% end %>
                      </div>
                    <% else %>
                      <div class="spec-value pending">— pending</div>
                    <% end %>
                  </div>

                  <div class="spec-section">
                    <div class="spec-label">Boundaries</div>
                    <div style="display: flex; flex-direction: column; gap: 8px; margin-top: 4px;">
                      <div>
                        <span style="font-size: 11px; color: var(--color-text-muted); display: block;">Egress domains</span>
                        <%= if Enum.any?(@session.spec_draft.boundaries.egress_domains) do %>
                          <div class="pill-container">
                            <%= for domain <- @session.spec_draft.boundaries.egress_domains do %>
                              <span class="pill"><%= domain %></span>
                            <% end %>
                          </div>
                        <% else %>
                          <span class="spec-value pending">— pending</span>
                        <% end %>
                      </div>

                      <div>
                        <span style="font-size: 11px; color: var(--color-text-muted); display: block;">Target locations</span>
                        <%= if Enum.any?(@session.spec_draft.boundaries.target_locations) do %>
                          <div class="pill-container">
                            <%= for loc <- @session.spec_draft.boundaries.target_locations do %>
                              <span class="pill"><%= loc %></span>
                            <% end %>
                          </div>
                        <% else %>
                          <span class="spec-value pending">— pending</span>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <div class="spec-section">
                    <div class="spec-label">Spend Limits</div>
                    <div style="display: flex; gap: 20px; margin-top: 4px;">
                      <div>
                        <span style="font-size: 11px; color: var(--color-text-muted); display: block;">Dollar cap</span>
                        <span class="spec-value">
                          <%= if @session.spec_draft.spend_limits.dollar_cap > 0, do: "$#{@session.spec_draft.spend_limits.dollar_cap}", else: "— pending" %>
                        </span>
                      </div>
                    </div>
                  </div>
                <% else %>
                  <div class="spec-value pending">No draft specification available yet.</div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("start_session", %{"purpose" => purpose}, socket) do
    case ElicitationSession.start_link(purpose) do
      {:ok, pid} ->
        session = ElicitationSession.get_state(pid)
        show_confirm = session.status == :confirmed

        {:noreply,
         assign(socket,
           session_pid: pid,
           session: session,
           show_confirm: show_confirm,
           purpose_input: ""
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start session: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("submit_message", %{"message" => message}, socket) do
    message = String.trim(message)

    if message == "" do
      {:noreply, socket}
    else
      pid = socket.assigns.session_pid

      case ElicitationSession.submit_message(pid, message) do
        {:ok, updated_session, next_q, creep, pushback} ->
          show_confirm = updated_session.status == :confirmed or next_q == ""

          {:noreply,
           assign(socket,
             session: updated_session,
             creep_warning: if(creep, do: pushback, else: nil),
             show_confirm: show_confirm,
             local_prompt: nil,
             message_input: ""
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("confirm_spec", _params, socket) do
    pid = socket.assigns.session_pid
    target_dir = Path.join(["specs", "012-elicit-spec"])
    File.mkdir_p!(target_dir)

    case ElicitationSession.write_spec(pid, target_dir) do
      :ok ->
        if Process.alive?(pid), do: GenServer.stop(pid)

        {:noreply,
         assign(socket,
           session_pid: nil,
           session: nil,
           success_message:
             "Elicited specification written successfully to specs/012-elicit-spec/elicited_spec.json!"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to write spec: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("refine_spec", _params, socket) do
    {:noreply,
     assign(socket,
       show_confirm: false,
       creep_warning: nil,
       local_prompt: "How should we adjust the specification?"
     )}
  end

  @impl true
  def handle_event("reset_flow", _params, socket) do
    {:noreply, assign(socket, success_message: nil)}
  end

  @impl true
  def handle_event("submit_key", %{"key" => "Enter", "shiftKey" => false}, socket) do
    # Form submission via enter key handled dynamically by form submit event or client
    {:noreply, socket}
  end

  @impl true
  def handle_event("submit_key", _params, socket) do
    {:noreply, socket}
  end
end
