defmodule AgentOS.Inventory do
  @moduledoc """
  Implements the standing inventory render (REQ-list-inventory).
  Extracts the manifest definition and the current runtime state from
  the RosterStore without communicating with the agent process.
  """

  @doc """
  Renders a human-readable standing inventory report.

  ## Parameters
    - `opts`: Keyword list that can override the `:manifest_path`.

  ## Returns
    - A multi-line string containing the rendered report.
  """
  @spec render(keyword()) :: binary()
  def render(opts \\ []) do
    # Safely attempt to read the agent config.
    # We use a try-rescue block to fall back to a default manifest path if the
    # application config is not fully initialized (e.g. during certain test configurations).
    agent_config =
      try do
        AgentOS.Provisioner.agent_config()
      rescue
        _ -> %{manifest_path: "manifests/discovery.md"}
      end

    # Retrieve the manifest path. Keyword.get/3 extracts the value of :manifest_path from opts,
    # and if not present, defaults to the one defined in the config.
    manifest_path = Keyword.get(opts, :manifest_path, agent_config.manifest_path)

    # load the YAML frontmatter manifest from the file system.
    # Elixir uses `case` for pattern matching on tagged tuples like `{:ok, val}` or `{:error, reason}`.
    case AgentOS.Manifest.load(manifest_path) do
      {:ok, manifest} ->
        # Fetch the current state snapshot from the StateStore GenServer named :roster_trust.
        snapshot = AgentOS.StateStore.snapshot("roster_trust")

        # Calculate the total number of records recorded in state.
        records_count = length(snapshot.records)

        # Search for the last digest entry.
        # |> is the pipe operator: it passes the result of the previous expression as
        # the first argument of the next function.
        last_digest =
          snapshot.records
          # Start searching from the most recent records first
          |> Enum.reverse()
          # If no value matches, return the string "none"
          |> Enum.find_value("none", fn
            # Pattern match on map to extract value of "digest" key.
            %{"digest" => text} -> text
            # Ignore other shapes of records.
            _ -> nil
          end)

        # Parse last run details
        last_run = parse_last_run(Keyword.get(opts, :run_log_path, "data/run_log.md"))

        last_run_details =
          if last_run.status == "unknown" do
            "No runs recorded."
          else
            cause_detail =
              if last_run.failure_cause, do: " (cause: #{last_run.failure_cause})", else: ""

            exit_detail =
              if last_run.exit_code, do: " (exit code: #{last_run.exit_code})", else: ""

            """
            Last Run Status: #{last_run.status}#{cause_detail}#{exit_detail}
            Last Run Trigger: #{last_run.trigger}
            Last Run Actions: #{last_run.actions}
            Last Run Items In / Dropped: #{last_run.items_in} / #{last_run.items_dropped}
            """
            |> String.trim_trailing()
          end

        # Build and return the final report string using multiline heredoc (`"""`).
        # `#{expression}` is used for string interpolation.
        """
        Agent OS Standing Inventory
        ===========================
        PURPOSE: #{manifest.purpose}
        TRIGGERS: #{inspect(manifest.triggers)}
        GRANTS: #{inspect(manifest.grants)}
        MOUNTS: #{inspect(manifest.mounts)}
        SPEND CAP: #{manifest.spend.cap}
        OWNER/SUPERVISION: #{manifest.owner} / #{manifest.supervision}

        LAST RUN STATE:
        Total Records: #{records_count}
        Last Digest: #{last_digest}
        #{last_run_details}
        """

      {:error, reason} ->
        # Return a formatted error message string if manifest loading failed.
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
end
