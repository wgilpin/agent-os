defmodule Mix.Tasks.AgentOs.Elicit do
  @moduledoc """
  Mix Task to start and drive the interactive agent specification elicitation loop.

  Usage:
      mix agent_os.elicit "your natural language purpose"
  """

  use Mix.Task

  alias AgentOS.ElicitationSession

  @impl Mix.Task
  def run(args) do
    # Application needs to be started to compile and load dependencies
    Application.ensure_all_started(:agent_os)

    case args do
      [purpose | _] ->
        IO.puts("=== Agent OS Specification Elicitor ===")
        IO.puts("Purpose: \"#{purpose}\"")
        IO.puts("Starting session...")

        case ElicitationSession.start_link(purpose) do
          {:ok, pid} ->
            session = ElicitationSession.get_state(pid)
            # Display first question
            first_question = List.last(session.transcript).content
            run_loop(pid, first_question)

          {:error, reason} ->
            IO.puts(
              :stderr,
              "Error starting elicitation session: #{inspect(reason)}"
            )
        end

      _ ->
        IO.puts(:stderr, "Usage: mix agent_os.elicit \"<purpose>\"")
    end
  end

  defp run_loop(pid, question) do
    IO.puts("\n[Elicitor] #{question}")

    input =
      case IO.gets("User > ") do
        :eof -> ""
        {:error, _} -> ""
        val when is_binary(val) -> String.trim(val)
      end

    case ElicitationSession.submit_message(pid, input) do
      {:ok, session, next_q, creep, pushback} ->
        if creep do
          IO.puts("\n[KISS Check Warning] #{pushback}")
        end

        if session.status == :confirmed or next_q == "" do
          confirm_and_write(pid, session)
        else
          run_loop(pid, next_q)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error during elicitation: #{inspect(reason)}")
    end
  end

  defp confirm_and_write(pid, session) do
    # Render final capability spec
    IO.puts("\n=== Proposed Specification Summary ===")
    IO.puts("Purpose: #{session.spec_draft.purpose}")
    IO.puts("Capabilities: #{inspect(session.spec_draft.capabilities)}")
    IO.puts("Boundaries:")
    IO.puts("  - Egress: #{inspect(session.spec_draft.boundaries.egress_domains)}")
    IO.puts("  - Target Locations: #{inspect(session.spec_draft.boundaries.target_locations)}")
    IO.puts("Spend Limits:")
    IO.puts("  - Dollar Cap: $#{session.spec_draft.spend_limits.dollar_cap}")
    IO.puts("  - Token Limit: #{session.spec_draft.spend_limits.token_limit}")
    IO.puts("=======================================")

    confirm_input =
      case IO.gets("Do you confirm this specification? (yes/no) ") do
        :eof -> "no"
        {:error, _} -> "no"
        val when is_binary(val) -> val |> String.trim() |> String.downcase()
      end

    if confirm_input in ["yes", "y"] do
      # Determine target specs directory (Stage 2 config directory)
      target_dir = Path.join(["specs", "012-elicit-spec"])
      File.mkdir_p!(target_dir)

      case ElicitationSession.write_spec(pid, target_dir) do
        :ok ->
          IO.puts(
            "\n[Success] Elicited spec written to #{Path.join(target_dir, "elicited_spec.json")}"
          )

        {:error, reason} ->
          IO.puts(:stderr, "\n[Error] Failed to write spec: #{inspect(reason)}")
      end
    else
      IO.puts("\nLet's continue refining the specification.")
      # Loop back to ask for refinement
      run_loop(pid, "How should we adjust the specification?")
    end
  end
end
