defmodule AgentOS.ExecutionMode do
  @moduledoc """
  The typed per-purpose classification, decided once before synthesis and recorded
  with the agent's artifacts.

  Exactly two values: `:deterministic` (the body hard-codes its tool call(s) and
  submits them directly to the gate — no LLM slot) or `:inference` (today's
  broker-completion body). The mode is a typed value, never a bare string or bare
  map (Constitution V).

  Classification (`classify/3`) and the on-disk sidecar (`store/3`, `load/2`,
  recorded at `agents/<agent_name>/execution_mode.json`) let judging, deployment,
  and humans read "what kind of agent is this" without asking the agent
  (Constitution VIII). Ambiguity resolves to `:inference` — a wrongly-deterministic
  agent silently fails its purpose; a wrongly-inference one merely costs more.
  """

  require Logger

  alias AgentOS.InferenceBroker

  @enforce_keys [:mode, :rationale]
  defstruct [:mode, :rationale]

  @type mode :: :deterministic | :inference
  @type t :: %__MODULE__{mode: mode(), rationale: String.t()}

  @modes [:deterministic, :inference]

  # Broker opts forwarded verbatim to InferenceBroker.complete/2 (deterministic-test seams).
  @broker_opt_keys [:provider_fn, :prices, :now]

  @doc "The two valid mode atoms."
  @spec values() :: [mode()]
  def values, do: @modes

  @doc """
  Parses a string or atom into a valid mode atom.

  Accepts `"deterministic"`/`:deterministic` and `"inference"`/`:inference`
  (and, as prose tolerance, `"inference-based"`). Anything else — including a bare
  map — is `{:error, :invalid_mode}`.
  """
  @spec parse(any()) :: {:ok, mode()} | {:error, :invalid_mode}
  def parse(:deterministic), do: {:ok, :deterministic}
  def parse(:inference), do: {:ok, :inference}
  def parse("deterministic"), do: {:ok, :deterministic}
  def parse("inference"), do: {:ok, :inference}
  def parse("inference-based"), do: {:ok, :inference}
  def parse(_), do: {:error, :invalid_mode}

  @doc "Serialises a mode struct to the JSON-encodable sidecar map."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{mode: mode, rationale: rationale}) do
    %{"mode" => Atom.to_string(mode), "rationale" => rationale}
  end

  @doc """
  Decodes a sidecar map/JSON string into a typed mode. Any unparseable shape falls
  back to the safe `:inference` default with a logged warning.
  """
  @spec from_json(any()) :: {:ok, t()} | {:error, :invalid_mode}
  def from_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> from_json(decoded)
      {:error, _} -> {:error, :invalid_mode}
    end
  end

  def from_json(%{"mode" => raw} = map) do
    case parse(raw) do
      {:ok, mode} -> {:ok, %__MODULE__{mode: mode, rationale: Map.get(map, "rationale", "")}}
      {:error, _} = err -> err
    end
  end

  def from_json(_), do: {:error, :invalid_mode}

  @doc """
  Classifies a purpose into an execution mode via a single broker completion.

  Poses "does fulfilling this purpose require reasoning over dynamic content at
  runtime?" and expects `{"mode": ..., "rationale": ...}`. The call uses the
  `agent_codegen_model` (overridable via `:model`); classification is one-off setup
  spend, same class as synthesis, and runs under the orchestrator's uncapped token.

  Inputs are the manifest + purpose ONLY (co-generation isolation: no elicitation
  transcript, no agent code, no judge content). ANY parse failure, broker error, or
  ambiguity resolves to `%ExecutionMode{mode: :inference}`, logged loudly.
  """
  @spec classify(String.t(), AgentOS.Manifest.t(), keyword()) :: {:ok, t()}
  def classify(agent_name, %AgentOS.Manifest{} = manifest, opts \\ [])
      when is_binary(agent_name) do
    run_token = Keyword.get(opts, :run_token)

    request = %{
      run_token: run_token,
      model: classifier_model(opts),
      messages: classification_messages(agent_name, manifest)
    }

    # A classifier failure must never crash generation — it resolves to the safe
    # :inference default. We catch broker error tuples AND a raised provider/broker
    # exception (e.g. a stub that has no classification branch).
    try do
      case InferenceBroker.complete(request, Keyword.take(opts, @broker_opt_keys)) do
        {:ok, %{completion: completion}} ->
          case parse_classification(completion) do
            {:ok, mode} ->
              {:ok, mode}

            {:error, reason} ->
              {:ok, default_inference("unparseable classifier output: #{inspect(reason)}")}
          end

        other ->
          {:ok, default_inference("classifier broker call failed: #{inspect(other)}")}
      end
    rescue
      e -> {:ok, default_inference("classifier raised: #{Exception.message(e)}")}
    end
  end

  @doc """
  Writes the mode sidecar to `agents/<agent_name>/execution_mode.json`.
  Written once per generation run; regeneration overwrites.
  """
  @spec store(String.t(), t(), keyword()) :: :ok | {:error, term()}
  def store(agent_name, %__MODULE__{} = mode, opts \\ []) when is_binary(agent_name) do
    path = sidecar_path(agent_name, opts)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(to_json(mode), pretty: true))
  end

  @doc """
  Loads the mode sidecar for an agent. A missing file returns the typed `:inference`
  default with a "pre-040 agent" rationale, so existing deployed agents need no
  migration and are judged/treated exactly as today.
  """
  @spec load(String.t(), keyword()) :: {:ok, t()}
  def load(agent_name, opts \\ []) when is_binary(agent_name) do
    path = sidecar_path(agent_name, opts)

    case File.read(path) do
      {:ok, content} ->
        case from_json(content) do
          {:ok, mode} -> {:ok, mode}
          {:error, _} -> {:ok, default_inference("corrupt execution_mode.json for #{agent_name}")}
        end

      {:error, _} ->
        {:ok, %__MODULE__{mode: :inference, rationale: "pre-040 agent (default)"}}
    end
  end

  # --- Internal helpers ----------------------------------------------------

  # The safe default whenever classification cannot confidently choose deterministic.
  defp default_inference(reason) do
    Logger.warning("ExecutionMode defaulting to :inference — #{reason}")
    %__MODULE__{mode: :inference, rationale: "defaulted to inference: #{reason}"}
  end

  defp parse_classification(completion) when is_binary(completion) do
    sanitized =
      completion
      |> String.trim()
      |> String.replace(~r/^```(?:json)?/i, "")
      |> String.replace(~r/```$/, "")
      |> String.trim()

    with {:ok, decoded} <- Jason.decode(sanitized),
         %{"mode" => raw} <- decoded,
         {:ok, mode} <- parse(raw) do
      {:ok, %__MODULE__{mode: mode, rationale: Map.get(decoded, "rationale", "")}}
    else
      _ -> {:error, :unparseable}
    end
  end

  defp parse_classification(_), do: {:error, :unparseable}

  defp classification_messages(agent_name, %AgentOS.Manifest{} = manifest) do
    system = """
    You classify whether a generated agent needs runtime inference. Answer exactly one
    question: does fulfilling this purpose require reasoning over dynamic content at
    runtime (composing, summarizing, deciding based on the incoming payload)?

    - If the purpose is a fixed action whose effect is identical regardless of the
      trigger payload (e.g. "send a hard-coded greeting on trigger"), answer
      "deterministic".
    - If it requires reasoning over dynamic runtime content, answer "inference".
    - When in doubt, answer "inference".

    Respond with JSON only: {"mode": "deterministic" | "inference", "rationale": "..."}
    """

    user = """
    Agent: #{agent_name}
    Purpose: #{manifest.purpose}
    """

    [
      %{role: "system", content: system},
      %{role: "user", content: user}
    ]
  end

  defp classifier_model(opts) do
    Keyword.get(opts, :model) ||
      Application.get_env(:agent_os, :agent_codegen_model, "agent-codegen-model")
  end

  defp sidecar_path(agent_name, opts) do
    base = Keyword.get(opts, :spec_dir, "agents")
    Path.join([base, agent_name, "execution_mode.json"])
  end
end
