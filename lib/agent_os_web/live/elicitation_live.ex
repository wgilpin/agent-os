defmodule AgentOSWeb.ElicitationLive do
  @moduledoc """
  Chat-driven elicitation workspace. On a confirmed spec, offers a per-run
  review-mode choice (default consent-gated) and starts the generation pipeline
  in a supervised async task, rendering live stage progress from PubSub events
  (FR-001/002/003). Verified by manual walkthrough — no unit tests
  (Constitution III).
  """
  use Phoenix.LiveView

  alias AgentOS.ElicitationSession
  alias AgentOS.Pipeline.Orchestrator.PipelineRun
  alias AgentOS.Pipeline.ProgressEvent

  # Ordered pipeline stages for the progress panel.
  @pipeline_stages [:manifest, :classify, :agent, :judge, :security_review, :deploy]

  @stage_labels %{
    manifest: "Manifest projection",
    classify: "Execution-mode classification",
    agent: "Agent synthesis",
    judge: "Judge (blind compliance)",
    security_review: "Security review",
    deploy: "Deploy"
  }

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
       message_input: "",
       # Spend cap is a UI control, not an elicitation topic (user decision):
       # editable in the spec panel, defaults to $0.10, overrides the draft.
       dollar_cap_input: "0.10",
       # Pipeline-run state (US1)
       confirmed_spec: nil,
       pipeline_state: :idle,
       run_id: nil,
       run_agent: nil,
       stage_states: %{},
       terminal: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Refresh-rejoin (FR-003): a reload mid-run carries ?run=&agent= — re-subscribe
    # to the live topic and rebuild what we can from the persisted run record.
    run_id = params["run"]
    agent = params["agent"]

    if is_binary(run_id) and run_id != "" and is_binary(agent) and agent != "" and
         socket.assigns.run_id != run_id do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(AgentOS.PubSub, ProgressEvent.run_topic(run_id))
      end

      {:noreply,
       socket
       |> assign(pipeline_state: :running, run_id: run_id, run_agent: agent)
       |> rebuild_from_record(agent, run_id)}
    else
      {:noreply, socket}
    end
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
      <%= if @confirmed_spec || @pipeline_state != :idle do %>
        <div class="landing-container">
          <div class="landing-card">
            <div class="landing-logo">
              <svg viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/></svg>
            </div>
            <h1>Specification Confirmed</h1>
            <%= if @success_message do %>
              <p><%= @success_message %></p>
            <% end %>

            <%= if @pipeline_state == :idle do %>
              <!-- Review-mode choice + start (FR-001): consent-gated is the default;
                   riskier modes must be explicitly selected. -->
              <form class="landing-form" phx-submit="start_pipeline">
                <label for="review_mode" style="font-size: 13px; text-align: left;">
                  Deploy review mode
                </label>
                <select name="review_mode" id="review_mode" style="padding: 8px;">
                  <option value="review_if_risky" selected>
                    Review if risky (permissions-dependent) — default
                  </option>
                  <option value="always_review">
                    Consent-gated (always review)
                  </option>
                  <option value="dangerously_skip_review">
                    DANGEROUS: skip human review
                  </option>
                </select>
                <button type="submit" class="btn-primary">Start Pipeline</button>
              </form>
              <button class="btn-refine" phx-click="reset_flow">Start New Elicitation</button>
            <% else %>
              <!-- Live stage-progress panel driven by PubSub events (FR-003). -->
              <div class="pipeline-progress" style="text-align: left; margin-top: 16px;">
                <h3>Pipeline run <code><%= @run_id %></code></h3>
                <ul style="list-style: none; padding: 0;">
                  <%= for stage <- pipeline_stages() do %>
                    <li style="padding: 4px 0;">
                      <span><%= stage_icon(Map.get(@stage_states, stage)) %></span>
                      <span><%= stage_label(stage) %></span>
                      <%= if detail = stage_detail_text(Map.get(@stage_states, stage)) do %>
                        <code style="font-size: 12px;">— <%= detail %></code>
                      <% end %>
                    </li>
                  <% end %>
                </ul>

                <%= case @terminal do %>
                  <% nil -> %>
                    <p class="pipeline-running">Running…</p>
                  <% %{status: :deployed, detail: provenance} -> %>
                    <div class="decision-banner decision-banner-approved">
                      <h2>Deployed</h2>
                      <p>Agent <strong><%= @run_agent %></strong> deployed (provenance: <%= provenance %>).
                        See <a href="/inventory">the inventory</a>.</p>
                    </div>
                  <% %{status: :blocked} -> %>
                    <div class="decision-banner">
                      <h2>Blocked — pending consent</h2>
                      <p>
                        Deployment is parked for human approval.
                        <a href={"/consent?manifest=manifests/#{@run_agent}.md"}>
                          Review and approve in the consent screen
                        </a>.
                      </p>
                    </div>
                  <% %{status: :stopped, detail: reason} -> %>
                    <div class="decision-banner decision-banner-rejected">
                      <h2>Stopped</h2>
                      <p>The pipeline stopped: <code><%= format_detail(reason) %></code></p>
                    </div>
                <% end %>

                <%= if @terminal do %>
                  <button class="btn-primary" phx-click="reset_flow">Start New Elicitation</button>
                <% end %>
              </div>
            <% end %>
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
              <a href="/inventory" class="landing-inventory-link">View deployed agents →</a>
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
                        <form phx-change="set_dollar_cap" style="margin: 0;">
                          <span class="spec-value" style="display: inline-flex; align-items: center; gap: 2px;">
                            $
                            <input
                              type="number"
                              name="dollar_cap"
                              value={@dollar_cap_input}
                              step="0.01"
                              min="0.01"
                              style="width: 70px; padding: 2px 4px; font: inherit;"
                            />
                          </span>
                        </form>
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
  def handle_event("set_dollar_cap", %{"dollar_cap" => raw}, socket) do
    {:noreply, assign(socket, dollar_cap_input: raw)}
  end

  @impl true
  def handle_event("confirm_spec", _params, socket) do
    pid = socket.assigns.session_pid
    target_dir = Path.join(["specs", "012-elicit-spec"])
    File.mkdir_p!(target_dir)

    # The UI's dollar cap is authoritative — the elicitor never asks about spend.
    # It must land in the session BEFORE write_spec so the file and the pipeline
    # input agree.
    case parse_dollar_cap(socket.assigns.dollar_cap_input) do
      {:ok, cap} ->
        :ok = ElicitationSession.set_dollar_cap(pid, cap)
        do_confirm_spec(pid, target_dir, socket)

      :error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Dollar cap must be a positive amount (got: #{inspect(socket.assigns.dollar_cap_input)})"
         )}
    end
  end

  @impl true
  def handle_event("start_pipeline", params, socket) do
    spec = socket.assigns.confirmed_spec
    review_mode = parse_review_mode(params["review_mode"])
    run_id = "run_#{System.unique_integer([:positive])}"
    agent_name = derive_agent_name(spec)

    # Subscribe BEFORE starting the run so no event is missed.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AgentOS.PubSub, ProgressEvent.run_topic(run_id))
    end

    # Fire-and-forget under the dedicated supervisor: the run must survive this
    # LiveView (FR-002) — never awaited, never linked.
    {:ok, _task_pid} =
      Task.Supervisor.start_child(AgentOS.PipelineTaskSupervisor, fn ->
        AgentOS.Pipeline.Orchestrator.run(spec, review_mode, run_id: run_id)
      end)

    {:noreply,
     socket
     |> assign(
       pipeline_state: :running,
       run_id: run_id,
       run_agent: agent_name,
       stage_states: %{},
       terminal: nil
     )
     |> push_patch(to: "/?run=#{run_id}&agent=#{agent_name}")}
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
    {:noreply,
     socket
     |> assign(
       success_message: nil,
       confirmed_spec: nil,
       pipeline_state: :idle,
       run_id: nil,
       run_agent: nil,
       stage_states: %{},
       terminal: nil
     )
     |> push_patch(to: "/")}
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

  @impl true
  def handle_info({:pipeline_progress, %ProgressEvent{} = event}, socket) do
    # Stale-run guard: only render events for the run this view owns.
    if event.run_id == socket.assigns.run_id do
      socket =
        if event.stage == :pipeline do
          assign(socket,
            terminal: %{status: event.status, detail: event.detail},
            run_agent: event.agent_name
          )
        else
          assign(socket,
            stage_states:
              Map.put(socket.assigns.stage_states, event.stage, %{
                status: event.status,
                detail: event.detail
              }),
            run_agent: event.agent_name
          )
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # --- Pipeline helpers ---

  # Whitelisted review-mode parse: unknown input falls back to the consent-gated
  # default; the dangerous mode is only reachable by explicit selection (FR-001).
  defp do_confirm_spec(pid, target_dir, socket) do
    # Capture the typed confirmed spec BEFORE stopping the session — it is the
    # pipeline's input (US1).
    session = ElicitationSession.get_state(pid)
    confirmed_spec = %{session.spec_draft | confirmed: true}

    case ElicitationSession.write_spec(pid, target_dir) do
      :ok ->
        if Process.alive?(pid), do: GenServer.stop(pid)

        {:noreply,
         assign(socket,
           session_pid: nil,
           session: nil,
           confirmed_spec: confirmed_spec,
           success_message:
             "Elicited specification written to specs/012-elicit-spec/elicited_spec.json. " <>
               "Choose a review mode and start the pipeline."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to write spec: #{inspect(reason)}")}
    end
  end

  # Parses the UI cap string; only positive amounts confirm (a zero cap makes an
  # inert agent — projection would reject it anyway; fail at the earliest surface).
  defp parse_dollar_cap(raw) when is_binary(raw) do
    case Float.parse(String.trim(raw)) do
      {cap, ""} when cap > 0 -> {:ok, cap}
      _ -> :error
    end
  end

  defp parse_review_mode("review_if_risky"), do: :review_if_risky
  defp parse_review_mode("dangerously_skip_review"), do: :dangerously_skip_review
  defp parse_review_mode(_), do: :always_review

  # Mirrors Orchestrator.determine_name/2 for display and consent-link purposes.
  defp derive_agent_name(spec) do
    spec.purpose
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
  end

  # Rebuilds panel state from the persisted run record after a refresh; a run
  # still in flight has no record yet — live events fill the panel as they land.
  defp rebuild_from_record(socket, agent, run_id) do
    case fetch_pipeline_run(agent) do
      %PipelineRun{run_id: ^run_id} = record ->
        stage_states =
          Enum.into(record.stages, %{}, fn %{stage: stage, status: status, detail: detail} ->
            {stage, %{status: if(status == :ok, do: :finished, else: :failed), detail: detail}}
          end)

        terminal =
          case record.outcome do
            :deployed -> %{status: :deployed, detail: record.provenance}
            :blocked -> %{status: :blocked, detail: elem(record.deploy_result, 1)}
            :stopped -> %{status: :stopped, detail: record.reason}
            nil -> nil
          end

        assign(socket, stage_states: stage_states, terminal: terminal)

      _ ->
        socket
    end
  end

  # Reads the persisted run record; tolerates a store that is not running.
  defp fetch_pipeline_run(agent) do
    AgentOS.StateStore.snapshot("pipeline_runs")[agent]
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp pipeline_stages, do: @pipeline_stages

  defp stage_label(stage), do: Map.get(@stage_labels, stage, to_string(stage))

  defp stage_icon(nil), do: "○"
  defp stage_icon(%{status: :started}), do: "◔"
  defp stage_icon(%{status: :finished}), do: "●"
  defp stage_icon(%{status: :failed}), do: "✕"

  # Text for a stage's detail chip, nil when there is nothing to show.
  defp stage_detail_text(%{detail: detail}) when not is_nil(detail) and detail != :ok,
    do: format_detail(detail)

  defp stage_detail_text(_), do: nil

  defp format_detail(detail) when is_binary(detail), do: detail
  defp format_detail(detail) when is_atom(detail), do: to_string(detail)
  defp format_detail(detail), do: inspect(detail)
end
