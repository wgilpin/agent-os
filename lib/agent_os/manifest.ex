defmodule AgentOS.Manifest do
  @moduledoc """
  Parser for the hand-written, human-kept declarative manifest.
  Enforces the v2 schema and validates constraints/connectors.

  ### Boundary Invariant
  The manifest is privileged-read for the gate only (substrate-only) and never
  crosses the port boundary into the agent container.
  Enforced by `test/agent_os/boundary_test.exs` (FR-007, VR-007).
  """

  alias AgentOS.Manifest.Grant
  alias AgentOS.Manifest.Spend
  alias AgentOS.Connector

  @enforce_keys [:purpose, :grants, :spend, :owner, :supervision]
  defstruct [:purpose, :triggers, :grants, :mounts, :spend, :owner, :supervision]

  @type trigger ::
          %{type: :time, at: String.t()}
          | %{type: :event, name: String.t()}
          | %{type: :message}

  @type t :: %__MODULE__{
          purpose: String.t(),
          triggers: [trigger()],
          grants: [Grant.t()],
          mounts: [String.t()],
          spend: Spend.t(),
          owner: String.t(),
          supervision: String.t()
        }

  @doc """
  Loads and parses a manifest file.

  ## Parameters
    - `path`: The absolute or relative path to the markdown manifest file.

  ## Returns
    - `{:ok, %AgentOS.Manifest{}}`
    - `{:error, reason}` if the file does not exist, cannot be read, or lacks frontmatter.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, any()}
  def load(path) do
    case File.read(path) do
      {:error, reason} ->
        {:error, reason}

      {:ok, content} ->
        case String.split(content, ~r/^-{3,}\s*\n/m, parts: 3) do
          [_leading, frontmatter, _body] ->
            case YamlElixir.read_from_string(frontmatter) do
              {:ok, raw_map} ->
                {:ok, parse_and_validate!(raw_map)}

              {:error, reason} ->
                {:error, reason}
            end

          _ ->
            {:error, :no_frontmatter}
        end
    end
  end

  defp parse_and_validate!(raw_map) do
    purpose = Map.get(raw_map, "purpose") || raise "Missing required field: purpose"
    owner = Map.get(raw_map, "owner") || raise "Missing required field: owner"
    supervision = Map.get(raw_map, "supervision") || raise "Missing required field: supervision"

    grants_raw = Map.get(raw_map, "grants") || raise "Missing required field: grants"
    if not is_list(grants_raw), do: raise("Field 'grants' must be a list")
    grants = Enum.map(grants_raw, &parse_grant!/1)

    spend_raw = Map.get(raw_map, "spend") || raise "Missing required field: spend"
    if not is_map(spend_raw), do: raise("Field 'spend' must be a map")
    spend = parse_spend!(spend_raw)

    mounts = Map.get(raw_map, "mounts", [])
    triggers_raw = Map.get(raw_map, "triggers", [])
    triggers = Enum.map(triggers_raw, &parse_trigger!/1)

    struct!(__MODULE__,
      purpose: purpose,
      owner: owner,
      supervision: supervision,
      grants: grants,
      spend: spend,
      mounts: mounts,
      triggers: triggers
    )
  end

  defp parse_grant!(raw_grant) do
    if not is_map(raw_grant), do: raise("Each grant must be a map")
    connector = Map.get(raw_grant, "connector") || raise "Grant is missing 'connector' field"
    if not is_binary(connector), do: raise("Grant 'connector' must be a string")

    case Connector.get(connector) do
      {:ok, _} -> :ok
      {:error, :unknown_connector} -> raise "Unknown connector: #{connector}"
    end

    recipients = Map.get(raw_grant, "recipients")

    if recipients != nil and not is_list(recipients),
      do: raise("Grant 'recipients' must be a list")

    methods = Map.get(raw_grant, "methods")
    if methods != nil and not is_list(methods), do: raise("Grant 'methods' must be a list")

    handle = Map.get(raw_grant, "handle")
    if handle != nil and not is_binary(handle), do: raise("Grant 'handle' must be a string")

    namespace = Map.get(raw_grant, "namespace")

    if namespace != nil and not is_binary(namespace),
      do: raise("Grant 'namespace' must be a string")

    struct!(Grant,
      connector: connector,
      recipients: recipients,
      methods: methods,
      handle: handle,
      namespace: namespace
    )
  end

  defp parse_spend!(raw_spend) do
    cap = Map.get(raw_spend, "cap") || raise "Spend is missing 'cap' field"
    if not is_number(cap) or cap < 0, do: raise("Spend 'cap' must be a non-negative number")

    window = Map.get(raw_spend, "window") || raise "Spend is missing 'window' field"

    window_atom =
      case window do
        "daily" -> :daily
        :daily -> :daily
        other -> raise "Unsupported spend window: #{inspect(other)}"
      end

    on_breach = Map.get(raw_spend, "on_breach") || raise "Spend is missing 'on_breach' field"

    on_breach_atom =
      case on_breach do
        "kill" -> :kill
        :kill -> :kill
        other -> raise "Unsupported spend on_breach: #{inspect(other)}"
      end

    struct!(Spend,
      cap: cap,
      window: window_atom,
      on_breach: on_breach_atom
    )
  end

  defp parse_trigger!(raw_trigger) do
    if not is_map(raw_trigger), do: raise("Each trigger must be a map")
    type = Map.get(raw_trigger, "type") || raise "Trigger is missing 'type' field"

    case type do
      "time" ->
        at = Map.get(raw_trigger, "at") || raise "Time trigger is missing 'at' field"
        %{type: :time, at: at}

      "event" ->
        name = Map.get(raw_trigger, "name") || raise "Event trigger is missing 'name' field"
        %{type: :event, name: name}

      "message" ->
        %{type: :message}

      other ->
        raise "Unsupported trigger type: #{inspect(other)}"
    end
  end
end
