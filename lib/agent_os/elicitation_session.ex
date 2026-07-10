defmodule AgentOS.ElicitationSession do
  @moduledoc """
  GenServer that manages the lifecycle of an elicitation conversation
  and communicates with the Python Elicitor Agent.
  """

  use GenServer

  alias AgentOS.ConversationSession
  alias AgentOS.ElicitedSpec
  alias AgentOS.PortRunner

  # Client API

  @doc """
  Starts a new elicitation session GenServer.
  """
  def start_link(original_purpose) do
    GenServer.start_link(__MODULE__, original_purpose)
  end

  @doc """
  Retrieves the current state of the conversation session.
  """
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  Submits a user message and returns the next response from the elicitor.
  """
  def submit_message(pid, message_content) do
    GenServer.call(pid, {:submit_message, message_content}, 60_000)
  end

  @doc """
  Writes the final spec file and shuts down the GenServer.
  """
  def write_spec(pid, target_dir) do
    GenServer.call(pid, {:write_spec, target_dir})
  end

  @doc """
  Overrides the draft's dollar spend cap with the UI-supplied value. The cap is a
  UI control (editable in the spec panel, default $0.10) — never an elicitation
  question, so the UI value is authoritative over whatever the elicitor drafted.
  """
  @spec set_dollar_cap(pid(), float()) :: :ok | {:error, :no_draft}
  def set_dollar_cap(pid, cap) when is_number(cap) and cap > 0 do
    GenServer.call(pid, {:set_dollar_cap, cap})
  end

  # Server Callbacks

  @impl true
  def init(original_purpose) do
    session_id = "session_" <> to_string(:os.system_time(:millisecond))
    run_token = Base.encode16(:crypto.strong_rand_bytes(16))

    # Construct system manifest for elicitation identity
    manifest = %AgentOS.Manifest{
      purpose: "Elicit specification",
      owner: "system",
      supervision: "none",
      grants: [],
      spend: %AgentOS.Manifest.Spend{
        cap: Application.get_env(:agent_os, :elicitor_spend_cap, 10_000_000),
        window: :daily,
        on_breach: :kill
      },
      mounts: [],
      triggers: []
    }

    if GenServer.whereis(AgentOS.InferenceBroker) do
      AgentOS.InferenceBroker.register(run_token, "elicitor", manifest)
    end

    initial_session = %ConversationSession{
      session_id: session_id,
      original_purpose: original_purpose,
      transcript: [
        %{role: :user, content: original_purpose, timestamp: DateTime.utc_now()}
      ],
      spec_draft: nil,
      status: :active
    }

    # Run initial elicitor step to get first question
    case run_elicitor(initial_session, run_token) do
      {:ok, result} ->
        # Create assistant response message
        assistant_message = %{
          role: :assistant,
          content: result["next_question"],
          timestamp: DateTime.utc_now()
        }

        updated_session = %ConversationSession{
          initial_session
          | transcript: initial_session.transcript ++ [assistant_message],
            spec_draft: ElicitedSpec.from_map(result["spec_draft"])
        }

        {:ok, {updated_session, result["next_question"], run_token}}

      {:error, reason} ->
        if GenServer.whereis(AgentOS.InferenceBroker) do
          AgentOS.InferenceBroker.unregister(run_token)
        end

        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, {_session, _next_question, run_token}) do
    if GenServer.whereis(AgentOS.InferenceBroker) do
      AgentOS.InferenceBroker.unregister(run_token)
    end

    :ok
  end

  @impl true
  def handle_call(:get_state, _from, {session, next_question, run_token}) do
    {:reply, session, {session, next_question, run_token}}
  end

  @impl true
  def handle_call({:submit_message, message_content}, _from, {session, prev_question, run_token}) do
    # 1. Add user message to transcript
    user_message = %{
      role: :user,
      content: message_content,
      timestamp: DateTime.utc_now()
    }

    session_with_user = %{session | transcript: session.transcript ++ [user_message]}

    # 2. Run elicitor
    case run_elicitor(session_with_user, run_token) do
      {:ok, result} ->
        spec_draft = ElicitedSpec.from_map(result["spec_draft"])
        next_q = result["next_question"]
        creep_detected = result["scope_creep_detected"]
        pushback = result["pushback_message"]

        # Add assistant response to transcript
        assistant_message = %{
          role: :assistant,
          content: if(creep_detected, do: pushback <> "\n" <> next_q, else: next_q),
          timestamp: DateTime.utc_now()
        }

        updated_session = %{
          session_with_user
          | transcript: session_with_user.transcript ++ [assistant_message],
            spec_draft: spec_draft
        }

        # The elicitor's structured `confirmed` flag is the confirmation signal.
        # Do NOT also require an empty next_question: the model often closes with
        # prose ("Spec confirmed. No further questions.") and nothing instructs it
        # to return an empty string, so gating on emptiness silently strands
        # confirmed sessions in :active (observed live). The human confirm click
        # remains the actual gate; this only surfaces the offer.
        updated_session =
          if spec_draft.confirmed do
            %{updated_session | status: :confirmed}
          else
            updated_session
          end

        {:reply, {:ok, updated_session, next_q, creep_detected, pushback},
         {updated_session, next_q, run_token}}

      {:error, reason} ->
        {:reply, {:error, reason}, {session, prev_question, run_token}}
    end
  end

  @impl true
  def handle_call({:set_dollar_cap, cap}, _from, {session, next_question, run_token}) do
    case session.spec_draft do
      nil ->
        {:reply, {:error, :no_draft}, {session, next_question, run_token}}

      draft ->
        updated_draft = %{draft | spend_limits: %{draft.spend_limits | dollar_cap: cap}}
        updated_session = %{session | spec_draft: updated_draft}
        {:reply, :ok, {updated_session, next_question, run_token}}
    end
  end

  @impl true
  def handle_call({:write_spec, target_dir}, _from, {session, next_question, run_token}) do
    if session.status != :confirmed do
      {:reply, {:error, :not_confirmed}, {session, next_question, run_token}}
    else
      # Persist elicited_spec.json
      spec_path = Path.join(target_dir, "elicited_spec.json")

      spec_json =
        Jason.encode!(
          %{
            "purpose" => session.spec_draft.purpose,
            "capabilities" => session.spec_draft.capabilities,
            "boundaries" => %{
              "egress_domains" => session.spec_draft.boundaries.egress_domains,
              "target_locations" => session.spec_draft.boundaries.target_locations
            },
            "spend_limits" => %{
              "dollar_cap" => session.spec_draft.spend_limits.dollar_cap,
              "token_limit" => session.spec_draft.spend_limits.token_limit
            },
            "triggers" =>
              Enum.map(session.spec_draft.triggers, fn t ->
                t_map = Map.new(t, fn {k, v} -> {to_string(k), v} end)
                Map.put(t_map, "type", to_string(t.type))
              end),
            "confirmed" => true
          },
          pretty: true
        )

      # Persist session state in data/elicitation/
      session_dir = Path.join("data", "elicitation")
      File.mkdir_p!(session_dir)
      session_path = Path.join(session_dir, "#{session.session_id}.json")
      File.write!(session_path, Jason.encode!(ConversationSession.to_map(session), pretty: true))

      case File.write(spec_path, spec_json) do
        :ok ->
          {:reply, :ok, {session, next_question, run_token}}

        {:error, reason} ->
          {:reply, {:error, reason}, {session, next_question, run_token}}
      end
    end
  end

  @doc """
  The connector registry's public capability vocabulary — the ONLY identifiers an
  elicited spec may request. Sent to the elicitor so it never invents ids; the
  same names the tool declarations already expose, so nothing manifest-private
  crosses the boundary.
  """
  @spec capability_vocabulary() :: [%{String.t() => String.t()}]
  def capability_vocabulary do
    AgentOS.Connector.registry()
    |> Enum.map(fn {id, meta} ->
      description =
        get_in(meta, [:tool_declaration, "function", "description"]) || id

      %{"id" => id, "description" => description}
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp run_elicitor(%ConversationSession{} = session, run_token) do
    # The elicitor must speak the registry's capability vocabulary — otherwise it
    # invents ids (observed live: 'Discord.send_message') that the manifest
    # projection rightly refuses at the registry gate.
    input_payload =
      session
      |> ConversationSession.to_map()
      |> Map.put("available_capabilities", capability_vocabulary())
      |> Jason.encode!()

    python_bin = System.get_env("PYTHON_BIN") || ".venv/bin/python"

    original_run_token = System.get_env("RUN_TOKEN")
    original_inf_socket = System.get_env("INFERENCE_SOCKET")

    System.put_env("RUN_TOKEN", run_token)

    System.put_env(
      "INFERENCE_SOCKET",
      Path.expand(Application.get_env(:agent_os, :inference_uds_path, "data/inference.sock"))
    )

    script =
      if System.get_env("MOCK_ELICITOR") == "true" do
        "agents/elicitor/mock_main.py"
      else
        "agents/elicitor/main.py"
      end

    res = PortRunner.run(input_payload, python_bin, [script])

    if original_run_token,
      do: System.put_env("RUN_TOKEN", original_run_token),
      else: System.delete_env("RUN_TOKEN")

    if original_inf_socket,
      do: System.put_env("INFERENCE_SOCKET", original_inf_socket),
      else: System.delete_env("INFERENCE_SOCKET")

    case res do
      {:ok, output} ->
        case Jason.decode(String.trim(output)) do
          {:ok, result} -> {:ok, result}
          {:error, err} -> {:error, {:invalid_json, err, output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
