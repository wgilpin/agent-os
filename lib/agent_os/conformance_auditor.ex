defmodule AgentOS.ConformanceAuditor do
  @moduledoc """
  Audits run records to determine compliance with constraints.
  """

  alias AgentOS.ConformanceAuditor.Verdict
  alias AgentOS.ConformanceAuditor.RunRecord
  alias AgentOS.ConformanceAuditor.Flag
  alias AgentOS.ConformanceAuditor.Alert
  alias AgentOS.RunLog
  alias AgentOS.StateStore
  alias AgentOS.Manifest

  @doc """
  Evaluates run records against auditor thresholds.
  """
  @spec audit([RunRecord.t()], String.t(), keyword()) :: Verdict.t()
  def audit(records, _purpose, opts \\ []) do
    agent = Keyword.get(opts, :agent, "agent")
    window = Keyword.get(opts, :window, 20)
    denied_threshold = Keyword.get(opts, :denied_threshold, 3)
    quiet_streak = Keyword.get(opts, :quiet_streak, 3)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    # Window selection: keep only the last N records
    windowed_records = Enum.take(records, -window)
    num_records = length(windowed_records)

    # Detect Leg 1 (health) and Leg 2 (trust) flags depending on history length
    {quiet_flags, sick_flags, gate_breach_flags, denied_approval_flags} =
      if num_records < window do
        # Short trace: only evaluate the hair-trigger gate_breach tripwire
        {[], [], check_gate_breach(windowed_records, window), []}
      else
        # Sufficient trace: evaluate all signals
        {
          check_quiet(windowed_records, quiet_streak),
          check_sick(windowed_records),
          check_gate_breach(windowed_records, window),
          check_denied_approval(windowed_records, denied_threshold)
        }
      end

    # Totality: list all flags (FR-007)
    flags = quiet_flags ++ sick_flags ++ gate_breach_flags ++ denied_approval_flags

    # Gate breach tripwire is evaluated even on a short trace (1 record is enough).
    # If any flag is raised, status is :flagged.
    # Otherwise, if trace is shorter than window, status is :insufficient_data.
    # Otherwise, status is :clean.
    status =
      cond do
        flags != [] ->
          :flagged

        num_records < window ->
          :insufficient_data

        true ->
          :clean
      end

    %Verdict{
      agent: agent,
      status: status,
      flags: flags,
      computed_at: now
    }
  end

  defp check_quiet(records, quiet_streak) do
    streak =
      records
      |> Enum.reverse()
      |> Enum.reduce_while(0, fn r, acc ->
        if r.actions == 0 do
          {:cont, acc + 1}
        else
          {:halt, acc}
        end
      end)

    if streak >= quiet_streak do
      [
        %Flag{
          type: :quiet,
          severity: :health,
          description: "No action in #{quiet_streak} consecutive runs"
        }
      ]
    else
      []
    end
  end

  defp check_sick(records) do
    alert_status? = Enum.any?(records, fn r -> r.status == "alert" end)

    rising_shed? =
      case Enum.take(records, -2) do
        [prev, latest] ->
          latest.items_dropped > 0 &&
            latest.items_in > 0 &&
            prev.items_in > 0 &&
            latest.items_dropped / latest.items_in > prev.items_dropped / prev.items_in

        _ ->
          false
      end

    cond do
      alert_status? ->
        [
          %Flag{
            type: :sick,
            severity: :health,
            description: "alert condition recorded in run trace"
          }
        ]

      rising_shed? ->
        [
          %Flag{
            type: :sick,
            severity: :health,
            description: "strictly-rising load shedding detected (items dropped/in)"
          }
        ]

      true ->
        []
    end
  end

  defp check_gate_breach(records, window) do
    breach? =
      Enum.any?(records, fn r ->
        r.breached_count > 0 || r.gate_reasons != []
      end)

    if breach? do
      [
        %Flag{
          type: :gate_breach,
          severity: :tripwire,
          description: "manifest-breach attempt recorded in last #{window} runs"
        }
      ]
    else
      []
    end
  end

  defp check_denied_approval(records, threshold) do
    denied_count =
      records
      |> Enum.filter(fn r ->
        r.trigger == "approval-resume" && String.starts_with?(r.note, "denied")
      end)
      |> length()

    if denied_count >= threshold do
      [
        %Flag{
          type: :denied_approval,
          severity: :count,
          description: "#{denied_count} approval-required actions denied in window"
        }
      ]
    else
      []
    end
  end

  @doc """
  Runs a conformance audit pass for the configured agent.
  """
  @spec run_pass(keyword()) :: Verdict.t()
  def run_pass(opts \\ []) do
    manifest_path =
      Keyword.get(opts, :manifest_path) ||
        Application.get_env(:agent_os, :manifest_path, "test/fixtures/manifests/discovery.md")

    agent = Path.basename(manifest_path, ".md")

    purpose =
      case Manifest.load(manifest_path) do
        {:ok, manifest} -> manifest.purpose
        _ -> "unknown"
      end

    run_log_path = Keyword.get(opts, :run_log_path) || AgentOS.RunLog.default_path()
    window = Keyword.get(opts, :window) || Application.get_env(:agent_os, :conformance_window, 20)
    records = RunLog.read_records(run_log_path, window: window)

    previous =
      try do
        StateStore.snapshot("conformance")[agent]
      rescue
        _ -> nil
      end

    prev_flags = if previous, do: previous.flags, else: []

    audit_opts =
      opts
      |> Keyword.put_new(:agent, agent)
      |> Keyword.put_new(:window, window)

    verdict = audit(records, purpose, audit_opts)

    try do
      StateStore.apply_action("conformance", {:put, agent, verdict})
    rescue
      _ -> :ok
    end

    escalated = detect_escalated_flags(verdict.flags, prev_flags)

    Enum.each(escalated, fn flag ->
      Alert.emit(agent, flag, opts)
    end)

    verdict
  end

  @doc false
  @spec detect_escalated_flags([Flag.t()], [Flag.t()]) :: [Flag.t()]
  def detect_escalated_flags(new_flags, prev_flags) do
    Enum.filter(new_flags, fn new_flag ->
      prev_flag = Enum.find(prev_flags || [], &(&1.type == new_flag.type))

      cond do
        is_nil(prev_flag) ->
          true

        Flag.less_than?(prev_flag.severity, new_flag.severity) ->
          true

        true ->
          false
      end
    end)
  end
end
