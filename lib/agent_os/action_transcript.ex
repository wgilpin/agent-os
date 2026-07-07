defmodule AgentOS.ActionTranscript do
  @moduledoc """
  A typed transcript of tool-call actions taken during an agent run.
  Persisted to a single-writer StateStore keyed by run token.
  """

  alias AgentOS.StateStore

  @store_name "action_transcript"

  defmodule Entry do
    @moduledoc "A single entry in an action transcript."
    @derive Jason.Encoder

    @type kind :: :granted | :rejected | :parked
    @type t :: %__MODULE__{
            kind: kind(),
            connector: String.t(),
            method: String.t() | nil,
            arguments: map(),
            result: map() | nil,
            reason_code: atom() | nil
          }

    defstruct [:kind, :connector, :method, :arguments, :result, :reason_code]

    @doc "Creates and validates a new Entry."
    def new(attrs) do
      kind = Map.fetch!(attrs, :kind)

      if kind == :rejected and is_nil(Map.get(attrs, :reason_code)) do
        raise ArgumentError, "a :rejected entry MUST carry a reason_code"
      end

      struct!(__MODULE__, attrs)
    end
  end

  @derive Jason.Encoder
  @type t :: %__MODULE__{
          run_token: String.t(),
          mode: :live | :record | nil,
          entries: [Entry.t()]
        }

  defstruct [:run_token, :mode, entries: []]

  @doc """
  Clears the transcript for the given run token.
  """
  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(run_token) when is_binary(run_token) do
    StateStore.apply_action(@store_name, {:delete_in, [run_token]})
  end

  @doc """
  Appends an entry to the transcript for the given run token.
  If this is the first entry, copies the mode from the broker registration.
  """
  @spec append(String.t(), Entry.t()) :: :ok | {:error, term()}
  def append(run_token, %Entry{} = entry) when is_binary(run_token) do
    current = read(run_token)

    mode =
      if is_nil(current.mode) do
        case AgentOS.InferenceBroker.resolve(run_token) do
          {:ok, %{mode: m}} -> m
          _ -> :live
        end
      else
        current.mode
      end

    if mode == :record and entry.kind == :granted do
      if entry.result != %{"status" => "recorded"} do
        raise ArgumentError,
              "result for a :record-mode :granted entry MUST be the synthetic success shape"
      end
    end

    updated = %__MODULE__{
      run_token: run_token,
      mode: mode,
      entries: current.entries ++ [entry]
    }

    StateStore.apply_action(@store_name, {:put, run_token, updated})
  end

  @doc """
  Reads the transcript for the given run token.
  Returns a new ActionTranscript struct if none exists.
  """
  @spec read(String.t()) :: t()
  def read(run_token) when is_binary(run_token) do
    case StateStore.snapshot(@store_name) do
      {:error, _} ->
        %__MODULE__{run_token: run_token, entries: []}

      map when is_map(map) ->
        case Map.get(map, run_token) do
          %__MODULE__{} = transcript ->
            transcript

          _ ->
            %__MODULE__{run_token: run_token, entries: []}
        end

      _ ->
        %__MODULE__{run_token: run_token, entries: []}
    end
  end
end
