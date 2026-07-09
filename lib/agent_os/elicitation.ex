defmodule AgentOS.ElicitedSpec do
  @moduledoc """
  Represents a strongly-typed specification elicited from a conversation.
  """

  @type t :: %__MODULE__{
          purpose: String.t(),
          capabilities: [String.t()],
          boundaries: %{
            egress_domains: [String.t()],
            target_locations: [String.t()]
          },
          spend_limits: %{
            dollar_cap: float(),
            token_limit: integer()
          },
          triggers: [AgentOS.Manifest.trigger()],
          confirmed: boolean()
        }

  defstruct [
    :purpose,
    :capabilities,
    boundaries: %{egress_domains: [], target_locations: []},
    spend_limits: %{dollar_cap: 0.0, token_limit: 0},
    triggers: [],
    confirmed: false
  ]

  @doc """
  Converts a map (usually parsed from JSON) into an ElicitedSpec struct.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    boundaries = Map.get(map, "boundaries", %{})
    spend_limits = Map.get(map, "spend_limits", %{})

    # Normalise triggers crossing the port boundary to canonical atom-keyed maps.
    # Malformed or unknown shapes from the (untrusted) elicitor are dropped, matching
    # Manifest.parse_trigger!/1 which rejects the same shapes on the load path.
    triggers =
      Map.get(map, "triggers", [])
      |> Enum.flat_map(fn t ->
        at = Map.get(t, "at") || Map.get(t, :at)
        name = Map.get(t, "name") || Map.get(t, :name)

        case Map.get(t, "type") || Map.get(t, :type) do
          type when type in ["startup", :startup] -> [%{type: :startup}]
          type when type in ["time", :time] and is_binary(at) and at != "" -> [%{type: :time, at: at}]
          type when type in ["event", :event] and is_binary(name) and name != "" -> [%{type: :event, name: name}]
          type when type in ["message", :message] -> [%{type: :message}]
          _ -> []
        end
      end)

    %__MODULE__{
      purpose: Map.get(map, "purpose"),
      capabilities: Map.get(map, "capabilities", []),
      boundaries: %{
        egress_domains: Map.get(boundaries, "egress_domains", []),
        target_locations: Map.get(boundaries, "target_locations", [])
      },
      spend_limits: %{
        dollar_cap: to_float(Map.get(spend_limits, "dollar_cap")),
        token_limit: to_integer(Map.get(spend_limits, "token_limit"))
      },
      triggers: triggers,
      confirmed: Map.get(map, "confirmed", false)
    }
  end

  defp to_float(nil), do: 0.0
  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0

  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_integer(nil), do: 0
  defp to_integer(v) when is_integer(v), do: v

  defp to_integer(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> 0
    end
  end
end

defmodule AgentOS.ConversationSession do
  @moduledoc """
  Manages the state of an active elicitation conversation.
  """

  @type message :: %{
          role: :user | :assistant | :system,
          content: String.t(),
          timestamp: DateTime.t() | String.t()
        }

  @type t :: %__MODULE__{
          session_id: String.t(),
          original_purpose: String.t(),
          transcript: [message()],
          spec_draft: AgentOS.ElicitedSpec.t() | nil,
          status: :active | :confirmed | :cancelled
        }

  defstruct [
    :session_id,
    :original_purpose,
    transcript: [],
    spec_draft: nil,
    status: :active
  ]

  @doc """
  Converts a map (parsed from JSON) into a ConversationSession struct.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    spec_draft_map = Map.get(map, "spec_draft")

    spec_draft =
      if is_map(spec_draft_map) do
        AgentOS.ElicitedSpec.from_map(spec_draft_map)
      else
        nil
      end

    transcript =
      map
      |> Map.get("transcript", [])
      |> Enum.map(fn msg ->
        %{
          role: String.to_existing_atom(Map.get(msg, "role")),
          content: Map.get(msg, "content"),
          timestamp: Map.get(msg, "timestamp")
        }
      end)

    status =
      case Map.get(map, "status", "active") do
        "active" -> :active
        "confirmed" -> :confirmed
        "cancelled" -> :cancelled
        other -> String.to_existing_atom(other)
      end

    %__MODULE__{
      session_id: Map.get(map, "session_id"),
      original_purpose: Map.get(map, "original_purpose"),
      transcript: transcript,
      spec_draft: spec_draft,
      status: status
    }
  end

  @doc """
  Converts a ConversationSession struct into a plain map for JSON encoding.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = session) do
    spec_draft_map =
      if session.spec_draft do
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
          "confirmed" => session.spec_draft.confirmed
        }
      else
        nil
      end

    transcript_list =
      Enum.map(session.transcript, fn msg ->
        %{
          "role" => to_string(msg.role),
          "content" => msg.content,
          "timestamp" => to_string(msg.timestamp)
        }
      end)

    %{
      "session_id" => session.session_id,
      "original_purpose" => session.original_purpose,
      "transcript" => transcript_list,
      "spec_draft" => spec_draft_map,
      "status" => to_string(session.status)
    }
  end
end
