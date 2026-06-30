defmodule AgentOS.RunLog do
  @moduledoc """
  Implements the legible append-only markdown run-log (REQ-read-run-trace).
  Writes ISO8601 timestamped entries describing execution outcomes, action counts,
  and notes to `data/run_log.md`.
  """

  @default_path Path.join(["data", "run_log.md"])

  @doc """
  Appends a single line description of a run to the run log.

  ## Parameters
    - `entry_map`: Map containing `:status` (atom/string), `:actions` (integer), and optionally `:note` (string).
    - `opts`: Keyword list to override the log path.
  """
  @spec append(map(), keyword()) :: :ok
  def append(entry_map, opts \\ []) do
    # Get the file path from options, defaulting to @default_path.
    path = Keyword.get(opts, :path, @default_path)

    # Generate the current UTC timestamp as an ISO-8601 string.
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    # Fetch values. Map.fetch!/2 raises a Keyerror if the key does not exist.
    # Map.get/3 returns the fallback value (empty string) if the key does not exist.
    status = Map.fetch!(entry_map, :status)
    actions = Map.fetch!(entry_map, :actions)
    note = Map.get(entry_map, :note, "")

    # Retrieve and format optional extended fields for container isolation logging
    exit_code_str = if ec = Map.get(entry_map, :exit_code), do: " exit_code=#{ec}", else: ""

    cause_str =
      if cause = Map.get(entry_map, :failure_cause), do: " failure_cause=#{cause}", else: ""

    items_str =
      if items_in = Map.get(entry_map, :items_in) do
        dropped = Map.get(entry_map, :items_dropped, 0)
        " items_in=#{items_in} items_dropped=#{dropped}"
      else
        ""
      end

    trigger_str =
      if trig = Map.get(entry_map, :trigger) do
        trig_str = to_string(trig)

        if String.contains?(trig_str, " ") do
          raise ArgumentError, "trigger provenance cannot contain whitespace: #{inspect(trig)}"
        end

        " trigger=#{trig_str}"
      else
        ""
      end

    gate_str =
      if Map.has_key?(entry_map, :approved_count) do
        ac = Map.get(entry_map, :approved_count, 0)
        rc = Map.get(entry_map, :rejected_count, 0)
        pc = Map.get(entry_map, :parked_count, 0)
        bc = Map.get(entry_map, :breached_count, 0)
        reasons = Map.get(entry_map, :gate_reasons, [])

        " approved_count=#{ac} rejected_count=#{rc} parked_count=#{pc} breached_count=#{bc} gate_reasons=#{inspect(reasons)}"
      else
        ""
      end

    # Format the line as a markdown list item.
    line =
      "- [#{timestamp}] status=#{status} actions=#{actions}#{trigger_str}#{exit_code_str}#{cause_str}#{items_str}#{gate_str} #{note}"

    # Ensure the parent directories of the file exist (equivalent to mkdir -p).
    File.mkdir_p!(Path.dirname(path))

    # Append the line with a trailing newline character to the file.
    # [:append] specifies to open the file in append-only mode.
    File.write!(path, line <> "\n", [:append])

    # Return :ok.
    :ok
  end

  @doc """
  Appends a digest entry line to the run log.

  ## Parameters
    - `text`: The raw text of the digest message to append.
    - `opts`: Keyword list to override the log path.
  """
  @spec append_digest(binary(), keyword()) :: :ok
  def append_digest(text, opts \\ []) do
    # Get target file path.
    path = Keyword.get(opts, :path, @default_path)

    # Generate timestamp.
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    # Format line.
    line = "- [#{timestamp}] digest: #{text}"

    # Ensure parent directory exists.
    File.mkdir_p!(Path.dirname(path))

    # Write line to the file in append mode.
    File.write!(path, line <> "\n", [:append])

    # Return :ok.
    :ok
  end

  @doc """
  Reads the run-log, keeps lines containing `status=` (excludes `digest:`),
  parses each into a `RunRecord`, skips unparsable lines with a `Logger.warning`,
  and returns the last `:window` records (default all) in chronological order.
  """
  @spec read_records(Path.t(), keyword()) :: [AgentOS.ConformanceAuditor.RunRecord.t()]
  def read_records(run_log_path, opts \\ []) do
    window = Keyword.get(opts, :window)

    if File.exists?(run_log_path) do
      records =
        File.stream!(run_log_path)
        |> Stream.filter(&String.contains?(&1, "status="))
        |> Stream.map(&parse_record_line/1)
        |> Stream.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, record} -> record end)

      if window do
        Enum.take(records, -window)
      else
        records
      end
    else
      []
    end
  end

  defp parse_record_line(line) do
    # Strip timestamp and extract fields
    status = extract_field_parser(line, ~r/\bstatus=([^\s]+)/)
    actions_str = extract_field_parser(line, ~r/\bactions=([^\s]+)/)

    if status && actions_str do
      case Integer.parse(actions_str) do
        {actions, _} ->
          trigger = extract_field_parser(line, ~r/\btrigger=([^\s]+)/)
          items_in = parse_int_parser(extract_field_parser(line, ~r/\bitems_in=([^\s]+)/), 0)

          items_dropped =
            parse_int_parser(extract_field_parser(line, ~r/\bitems_dropped=([^\s]+)/), 0)

          rejected_count =
            parse_int_parser(extract_field_parser(line, ~r/\brejected_count=([^\s]+)/), 0)

          parked_count =
            parse_int_parser(extract_field_parser(line, ~r/\bparked_count=([^\s]+)/), 0)

          breached_count =
            parse_int_parser(extract_field_parser(line, ~r/\bbreached_count=([^\s]+)/), 0)

          gate_reasons_str = extract_field_parser(line, ~r/\bgate_reasons=(\[[^\]]*\])/)

          gate_reasons =
            if gate_reasons_str do
              try do
                {list, _} = Code.eval_string(gate_reasons_str)
                if is_list(list), do: Enum.map(list, &to_string/1), else: []
              rescue
                _ -> []
              end
            else
              []
            end

          # Strip fields to get the note
          fields_regex =
            ~r/\b(status|actions|trigger|exit_code|failure_cause|items_in|items_dropped|approved_count|rejected_count|parked_count|breached_count)=\S+|\bgate_reasons=\[[^\]]*\]/

          note =
            line
            |> String.replace(~r/^- \[.*?\]/, "")
            |> String.replace(fields_regex, "")
            |> String.replace(~r/\s+/, " ")
            |> String.trim()

          {:ok,
           %AgentOS.ConformanceAuditor.RunRecord{
             status: status,
             actions: actions,
             trigger: trigger,
             items_in: items_in,
             items_dropped: items_dropped,
             rejected_count: rejected_count,
             parked_count: parked_count,
             breached_count: breached_count,
             gate_reasons: gate_reasons,
             note: note
           }}

        :error ->
          require Logger
          Logger.warning("Failed to parse run-log line actions count: #{String.trim(line)}")
          {:error, :malformed}
      end
    else
      require Logger
      Logger.warning("Failed to parse run-log line status or actions: #{String.trim(line)}")
      {:error, :malformed}
    end
  end

  defp extract_field_parser(line, regex) do
    case Regex.run(regex, line) do
      [_, val] -> val
      _ -> nil
    end
  end

  defp parse_int_parser(nil, default), do: default

  defp parse_int_parser(str, default) do
    case Integer.parse(str) do
      {val, _} -> val
      :error -> default
    end
  end
end
