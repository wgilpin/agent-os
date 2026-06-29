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
end
