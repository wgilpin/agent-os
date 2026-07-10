defmodule AgentOS.Pipeline.ProgressEvent do
  @moduledoc """
  Typed live-progress event published by the pipeline orchestrator (FR-003/FR-010).

  Broadcast on `AgentOS.PubSub` to two topics — the per-run topic
  `"pipeline:" <> run_id` (consumed by the elicitation UI) and the firehose
  `"pipeline:all"` (consumed by the inventory) — as `{:pipeline_progress, event}`.
  Events are observability, not control flow: broadcast failure is logged, never
  raised, and never persisted; refresh reconstruction reads the persisted
  PipelineRun record instead.
  """

  require Logger

  @typedoc "Pipeline stage the event refers to; :pipeline marks terminal events."
  @type stage ::
          :manifest | :classify | :agent | :judge | :security_review | :deploy | :pipeline

  @typedoc "Stage lifecycle or terminal outcome status."
  @type status :: :started | :finished | :failed | :deployed | :blocked | :stopped

  @type t :: %__MODULE__{
          run_id: String.t(),
          agent_name: String.t(),
          stage: stage(),
          status: status(),
          detail: term(),
          at: DateTime.t()
        }

  @enforce_keys [:run_id, :agent_name, :stage, :status, :at]
  defstruct [:run_id, :agent_name, :stage, :status, :detail, :at]

  @doc """
  Builds a progress event stamped with the current UTC time.
  """
  @spec new(String.t(), String.t(), stage(), status(), term()) :: t()
  def new(run_id, agent_name, stage, status, detail \\ nil) do
    %__MODULE__{
      run_id: run_id,
      agent_name: agent_name,
      stage: stage,
      status: status,
      detail: detail,
      at: DateTime.utc_now()
    }
  end

  @doc """
  Returns the per-run PubSub topic for a run id.
  """
  @spec run_topic(String.t()) :: String.t()
  def run_topic(run_id), do: "pipeline:" <> run_id

  @doc """
  Returns the firehose topic carrying every run's events (inventory consumer).
  """
  @spec all_topic() :: String.t()
  def all_topic, do: "pipeline:all"

  @doc """
  Broadcasts the event to both the per-run topic and the firehose topic as
  `{:pipeline_progress, event}`. Failures (e.g. PubSub not started in a minimal
  test tree) are logged and swallowed — progress must never abort a pipeline.
  """
  @spec broadcast(t()) :: :ok
  def broadcast(%__MODULE__{} = event) do
    message = {:pipeline_progress, event}

    for topic <- [run_topic(event.run_id), all_topic()] do
      try do
        Phoenix.PubSub.broadcast(AgentOS.PubSub, topic, message)
      rescue
        error ->
          Logger.warning(
            "ProgressEvent: broadcast to #{topic} failed: #{inspect(error)} — continuing"
          )
      catch
        :exit, reason ->
          Logger.warning(
            "ProgressEvent: broadcast to #{topic} exited: #{inspect(reason)} — continuing"
          )
      end
    end

    :ok
  end
end
