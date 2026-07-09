defmodule AgentOS.Inventory do
  @moduledoc """
  Implements the standing inventory render (REQ-list-inventory).
  Extracts the manifest definition and the current runtime state from
  the RosterStore without communicating with the agent process.
  """

  require Logger

  alias AgentOS.ConformanceAuditor.Verdict

  @default_manifests_glob "manifests/*.md"

  @judge_disclaimer "Scope: CODE-MATCHES-MANIFEST. This does not verify human intent correctness."
  @security_review_disclaimer "Scope: PROBABILISTIC CODE REVIEW. Disclaimer: Security review is a probabilistic LLM smoke detector."

  @doc """
  Returns structured inventory data.

  ## Parameters
    - `opts`: Keyword list that can override the `:manifest_path` or `:now` clock.

  ## Returns
    - `{:ok, map()}` on success or `{:error, reason}` on failure.
  """
  @spec data(keyword()) :: {:ok, map()} | {:error, any()}
  def data(opts \\ []) do
    case resolve_manifest_path(opts) do
      nil -> {:error, :no_manifest_path}
      manifest_path -> load_agent(manifest_path, opts)
    end
  end

  @doc """
  Enumerates every agent manifest under `manifests/*.md` and returns structured
  inventory data for each. The agent inventory is manifest-driven: there is no
  hard-wired agent name. Manifests that fail to load are skipped with a logged
  warning rather than silently substituting a default.

  ## Parameters
    - `opts`: forwarded to `data/1` (e.g. `:now`, `:run_log_path`). `:manifests_glob`
      overrides the manifest directory glob (used by hermetic tests).

  ## Returns
    - A list of inventory data maps, sorted by `:agent_name`.
  """
  @spec all(keyword()) :: [map()]
  def all(opts \\ []) do
    glob = Keyword.get(opts, :manifests_glob, @default_manifests_glob)
    per_agent_opts = Keyword.drop(opts, [:manifest_path, :manifests_glob])

    glob
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case data(Keyword.put(per_agent_opts, :manifest_path, path)) do
        {:ok, data} ->
          [data]

        {:error, reason} ->
          Logger.warning("inventory: skipping manifest #{path}: #{inspect(reason)}")
          []
      end
    end)
    |> Enum.sort_by(& &1.agent_name)
  end

  # Resolves the manifest path from opts, falling back to the global (test-only)
  # :manifest_path config. Returns nil when nothing is configured — the caller
  # surfaces that as an error rather than defaulting to the discovery fixture.
  defp resolve_manifest_path(opts) do
    Keyword.get(opts, :manifest_path) || Application.get_env(:agent_os, :manifest_path)
  end

  defp load_agent(manifest_path, opts) do
    case AgentOS.Manifest.load(manifest_path) do
      {:ok, manifest} ->
        agent_name = Path.basename(manifest_path, ".md")

        snapshot = AgentOS.StateStore.snapshot("roster_trust")
        records_count = length(snapshot.records)

        last_digest =
          snapshot.records
          |> Enum.reverse()
          |> Enum.find_value("none", fn
            %{"digest" => text} -> text
            _ -> nil
          end)

        last_run = parse_last_run(Keyword.get(opts, :run_log_path, "data/run_log.md"))

        now = Keyword.get(opts, :now, DateTime.utc_now())
        spend_ledger = AgentOS.StateStore.snapshot("spend_ledger")
        raw_entry = Map.get(spend_ledger, agent_name, %{spent: 0, window_start: now})
        entry = AgentOS.SpendLedger.current_entry(raw_entry, now, manifest.spend.window)

        pending_store = AgentOS.StateStore.snapshot("pending_approvals")
        approvals = Map.get(pending_store, :approvals, %{})

        grant_connectors = Enum.map(manifest.grants, & &1.connector)

        filtered_approvals =
          approvals
          |> Enum.sort_by(fn {ref, _} -> ref end)
          |> Enum.filter(fn {_ref, %{action: action}} ->
            action.recipient == agent_name or
              (action.type == "deploy" and Path.basename(action.method, ".md") == agent_name) or
              Enum.member?(grant_connectors, action.type) or
              action.recipient == nil
          end)
          |> Enum.map(fn {_ref, val} -> val end)

        capabilities = AgentOS.CapabilityRender.entries(manifest)

        provenance = try_get_provenance(agent_name)
        conformance = try_get_conformance_verdict(agent_name)
        judge = try_get_judge(agent_name)
        security_review = try_get_security_review(agent_name)

        {:ok,
         %{
           agent_name: agent_name,
           purpose: manifest.purpose,
           triggers: manifest.triggers,
           mounts: manifest.mounts,
           owner: manifest.owner,
           supervision: manifest.supervision,
           spend_cap: manifest.spend.cap,
           spend_window: manifest.spend.window,
           spent: entry.spent,
           records_count: records_count,
           last_digest: last_digest,
           last_run: last_run,
           provenance: provenance,
           conformance: conformance,
           judge: judge,
           security_review: security_review,
           pending_approvals: filtered_approvals,
           capabilities: capabilities
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Renders a human-readable standing inventory report.

  ## Parameters
    - `opts`: Keyword list that can override the `:manifest_path` or `:now` clock.

  ## Returns
    - A multi-line string containing the rendered report.
  """
  @spec render(keyword()) :: binary()
  def render(opts \\ []) do
    case data(opts) do
      {:ok, info} ->
        last_run_details =
          if info.last_run.status == "unknown" do
            "No runs recorded."
          else
            cause_detail =
              if info.last_run.failure_cause,
                do: " (cause: #{info.last_run.failure_cause})",
                else: ""

            exit_detail =
              if info.last_run.exit_code, do: " (exit code: #{info.last_run.exit_code})", else: ""

            """
            Last Run Status: #{info.last_run.status}#{cause_detail}#{exit_detail}
            Last Run Trigger: #{info.last_run.trigger}
            Last Run Actions: #{info.last_run.actions}
            Last Run Items In / Dropped: #{info.last_run.items_in} / #{info.last_run.items_dropped}
            """
            |> String.trim_trailing()
          end

        pending_approvals_str =
          if Enum.empty?(info.pending_approvals) do
            ""
          else
            lines =
              info.pending_approvals
              |> Enum.map(fn %{ref: ref, action: action} ->
                recipient_part = if action.recipient, do: " → #{action.recipient}", else: ""
                "  #{ref}  #{action.type}#{recipient_part}"
              end)
              |> Enum.join("\n")

            "\nPending approvals:\n" <> lines <> "\n"
          end

        capabilities_str =
          info.capabilities
          |> AgentOS.CapabilityRender.format()
          |> String.split("\n", trim: true)
          |> Enum.map(&"        #{&1}")
          |> Enum.join("\n")

        provenance_str =
          case info.provenance do
            nil ->
              "DEPLOY PROVENANCE: unknown"

            provenance ->
              provenance_val =
                case provenance.status do
                  :reviewed_human ->
                    "reviewed=human"

                  :skipped_in_envelope ->
                    "skipped-in-envelope"

                  :dangerously_skipped ->
                    "dangerously-skipped"

                  :failed ->
                    reason_str =
                      case Map.get(provenance, :failure_reason) do
                        :judge_failed -> "judge"
                        :security_review_failed -> "security-review"
                        :both_failed -> "both"
                        :missing_verdict -> "missing/stale verdict"
                        :stale_verdict -> "missing/stale verdict"
                        _ -> "unknown"
                      end

                    "failed (check: #{reason_str})"

                  :blocked ->
                    "blocked"

                  other ->
                    to_string(other)
                end

              "DEPLOY PROVENANCE: #{provenance_val}"
          end

        conformance_str =
          case info.conformance do
            nil ->
              "CONFORMANCE: insufficient data (#{info.records_count} runs recorded)"

            %Verdict{status: :insufficient_data} ->
              "CONFORMANCE: insufficient data (#{info.records_count} runs recorded)"

            %Verdict{status: :clean} ->
              "CONFORMANCE: clean"

            %Verdict{status: :flagged, flags: flags} ->
              flag_lines =
                flags
                |> Enum.map(fn flag ->
                  axis =
                    case flag.type do
                      :quiet -> "health"
                      :sick -> "health"
                      :denied_approval -> "trust"
                      :gate_breach -> "trust"
                    end

                  type_str =
                    flag.type
                    |> to_string()
                    |> String.replace("_", "-")

                  prefix = String.pad_trailing("  [#{axis}]", 10)
                  "#{prefix} #{type_str} — #{flag.description}"
                end)
                |> Enum.join("\n")

              "CONFORMANCE: flagged\n" <> flag_lines
          end

        judge_str = format_judge(info.judge)
        security_review_str = format_security_review(info.security_review)

        """
        Agent OS Standing Inventory
        ===========================
        PURPOSE: #{info.purpose}
        TRIGGERS: #{inspect(info.triggers)}
        #{capabilities_str}
        #{provenance_str}
        MOUNTS: #{inspect(info.mounts)}
        SPEND: #{format_dollars(info.spent)} / #{format_dollars(info.spend_cap)} per #{info.spend_window}
        OWNER/SUPERVISION: #{info.owner} / #{info.supervision}

        LAST RUN STATE:
        Total Records: #{info.records_count}
        Last Digest: #{info.last_digest}
        #{last_run_details}
        #{conformance_str}
        #{judge_str}
        #{security_review_str}
        """
        |> String.trim_trailing()
        |> Kernel.<>(pending_approvals_str)
        |> Kernel.<>("\n")

      {:error, reason} ->
        manifest_path = resolve_manifest_path(opts) || "(no manifest configured)"
        "ERROR: Could not load manifest at #{manifest_path}: #{inspect(reason)}"
    end
  end

  defp parse_last_run(run_log_path) do
    if File.exists?(run_log_path) do
      File.stream!(run_log_path)
      |> Enum.to_list()
      |> Enum.reverse()
      |> Enum.find(fn line -> String.contains?(line, "status=") end)
      |> case do
        nil ->
          %{status: "unknown"}

        line ->
          status = extract_field(line, ~r/status=([^\s]+)/)
          actions = extract_field(line, ~r/actions=([^\s]+)/)
          trigger = extract_field(line, ~r/trigger=([^\s]+)/)
          exit_code = extract_field(line, ~r/exit_code=([^\s]+)/)
          failure_cause = extract_field(line, ~r/failure_cause=([^\s]+)/)
          items_in = extract_field(line, ~r/items_in=([^\s]+)/)
          items_dropped = extract_field(line, ~r/items_dropped=([^\s]+)/)

          %{
            status: status || "unknown",
            actions: actions || "0",
            trigger: trigger || "timer",
            exit_code: exit_code,
            failure_cause: failure_cause,
            items_in: items_in || "0",
            items_dropped: items_dropped || "0"
          }
      end
    else
      %{status: "unknown"}
    end
  end

  defp extract_field(line, regex) do
    case Regex.run(regex, line) do
      [_, val] -> val
      _ -> nil
    end
  end

  defp format_dollars(micro_dollars) do
    dollars = micro_dollars / 1_000_000
    "$" <> :erlang.float_to_binary(dollars, [:compact, decimals: 6])
  end

  defp try_get_conformance_verdict(agent_name) do
    try do
      AgentOS.StateStore.snapshot("conformance")[agent_name]
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp try_get_provenance(agent_name) do
    try do
      AgentOS.StateStore.snapshot("provenance")[agent_name]
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp format_judge(nil) do
    "JUDGE: unrun"
  end

  defp format_judge(entry) do
    status_str =
      case Map.get(entry, :status) do
        :pass -> "pass"
        :fail -> "fail"
        :error -> "error"
        :unrun -> "unrun"
        other -> to_string(other)
      end

    run_detail =
      case Map.get(entry, :last_run) do
        %DateTime{} = dt -> " (last run: #{DateTime.to_iso8601(dt)})"
        _ -> ""
      end

    "JUDGE: #{status_str}#{run_detail}\n#{@judge_disclaimer}"
  end

  defp try_get_judge(agent_name) do
    try do
      AgentOS.StateStore.snapshot("judge_results")[agent_name]
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp format_security_review(nil) do
    "SECURITY REVIEW: unrun"
  end

  defp format_security_review(entry) do
    status_str =
      case Map.get(entry, :status) do
        :pass -> "pass"
        :fail -> "fail"
        :error -> "error"
        other -> to_string(other)
      end

    run_detail =
      case Map.get(entry, :timestamp) do
        %DateTime{} = dt -> " (reviewed at: #{DateTime.to_iso8601(dt)})"
        _ -> ""
      end

    reasoning = Map.get(entry, :reasoning) || ""
    reasoning_str = if reasoning != "", do: "\nReasoning: #{reasoning}", else: ""

    "SECURITY REVIEW: #{status_str}#{run_detail}#{reasoning_str}\n#{@security_review_disclaimer}"
  end

  defp try_get_security_review(agent_name) do
    try do
      AgentOS.StateStore.snapshot("security_review_results")[agent_name]
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end
end
