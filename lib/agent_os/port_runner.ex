defmodule AgentOS.PortRunner do
  @moduledoc """
  Implements the BEAM↔Python boundary via Erlang Ports.
  It starts the stdin-guard wrapper, feeds input, collects output,
  and manages timeout and child exit code surfacing.
  """

  @doc """
  Runs an external command inside the stdin-guard wrapper.
  Feeds `input_json` into the process stdin and waits for it to exit.

  ## Parameters
    - `input_json`: JSON string to feed to the child's stdin.
    - `cmd`: Executable name/path (e.g. "python").
    - `args`: List of command line arguments.
    - `opts`: Options keyword list (e.g., `[timeout_ms: 1000]`).
  """
  @spec run(binary(), binary(), [binary()], keyword()) ::
          {:ok, binary()} | {:error, {:exit_status, integer()}} | {:error, :timeout}
  def run(input_json, cmd, args, opts \\ []) do
    # Extract the timeout, defaulting to 30 seconds.
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    # Resolve the path to the bash wrapper script in the build's priv/ directory.
    wrapper = Path.join(:code.priv_dir(:agent_os), "port_wrapper.sh")

    # Open the Erlang Port.
    # `:spawn_executable` runs the given script (the wrapper), passing arguments.
    # Port options:
    # - `:binary` -> data returned as binaries, not Erlang lists of bytes.
    # - `:exit_status` -> enables receiving exit code messages.
    # - `{:args, ...}` -> command line arguments passed to the spawned wrapper executable.
    # - `{:line, 1_000_000}` -> buffers data into lines, returning lines up to 1MB.
    port =
      Port.open(
        {:spawn_executable, wrapper},
        [
          :binary,
          :exit_status,
          {:args, [cmd | args]},
          {:line, 1_000_000}
        ]
      )

    # Feed input on stdin, ending with a newline.
    # The python agent reads exactly one line from stdin.
    # `<>` is Elixir's binary/string concatenation operator.
    Port.command(port, input_json <> "\n")

    # Start the message collection loop, accumulating output in an empty list.
    collect(port, [], timeout_ms)
  end

  # A private recursive function that acts as the receive loop for the Port.
  # Elixir pattern-matches on messages arriving in the mailbox.
  defp collect(port, acc, timeout_ms) do
    receive do
      # Arriving data ending with a newline: append to accumulator and recurse.
      # Pin operator `^port` ensures we match messages from this specific Port instance only.
      {^port, {:data, {:eol, chunk}}} ->
        collect(port, [acc, chunk, "\n"], timeout_ms)

      # Arriving data segment without a newline: append to accumulator and recurse.
      {^port, {:data, {:noeol, chunk}}} ->
        collect(port, [acc, chunk], timeout_ms)

      # Raw binary stream fallback (if line mode was bypassed).
      {^port, {:data, chunk}} when is_binary(chunk) ->
        collect(port, [acc, chunk], timeout_ms)

      # Exit status 0 (success): reconstruct the accumulated iodata list into a single binary.
      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      # Non-zero exit status: return the error tuple.
      {^port, {:exit_status, code}} ->
        {:error, {:exit_status, code}}
    after
      # If no message is received for `timeout_ms` milliseconds, trigger timeout handling.
      timeout_ms ->
        # Port.close closes stdin, triggering the wrapper script to kill the child.
        Port.close(port)
        {:error, :timeout}
    end
  end
end
