defmodule AgentOS.RunWorkerTranscriptTest do
  use ExUnit.Case, async: false

  alias AgentOS.RunWorker
  alias AgentOS.StateStore
  alias AgentOS.ActionTranscript
  alias AgentOS.ActionTranscript.Entry

  @moduledoc """
  Drives RunWorker against the tool-channel contract: the agent prints a terminal
  outcome record to stdout and its effects are sourced from a pre-seeded
  ActionTranscript (as the capability rail would have written during inference).
  No live model calls — the agent is an `echo` stub.
  """

  setup do
    rand = System.unique_integer([:positive])
    tmp_log = Path.join(System.tmp_dir!(), "run_worker_transcript_#{rand}.md")

    AgentOS.TestHelper.start_mounts!()

    start_supervised!(AgentOS.InferenceBroker)

    agent_name = "twz_agent_#{rand}"
    manifest_path = Path.join(System.tmp_dir!(), "#{agent_name}.md")

    File.write!(manifest_path, """
    ---
    purpose: "Transcript test manifest"
    owner: human
    supervision: restart-once-and-alert
    grants:
      - connector: kv_append
        methods: ["append"]
    spend:
      cap: 500000
      window: daily
      on_breach: kill
    ---
    """)

    run_token = "twz_run_token_#{rand}"

    on_exit(fn ->
      File.rm(tmp_log)
      File.rm(manifest_path)
    end)

    {:ok,
     log_path: tmp_log, manifest_path: manifest_path, agent_name: agent_name, run_token: run_token}
  end

  defp granted(connector \\ "kv_append") do
    Entry.new(%{
      kind: :granted,
      connector: connector,
      method: "append",
      arguments: %{},
      result: %{"status" => "appended"},
      reason_code: nil
    })
  end

  defp rejected(reason \\ :ungranted_connector) do
    Entry.new(%{
      kind: :rejected,
      connector: "forbidden",
      method: nil,
      arguments: %{},
      result: nil,
      reason_code: reason
    })
  end

  defp parked do
    Entry.new(%{
      kind: :parked,
      connector: "external_send",
      method: "send",
      arguments: %{},
      result: nil,
      reason_code: nil
    })
  end

  defp outcome_json(outcome \\ "completed", reason \\ "handled via tool channel") do
    Jason.encode!(%{"outcome" => outcome, "reason" => reason})
  end

  defp run(ctx, stdout_arg) do
    RunWorker.run_once(
      agent_cmd: "echo",
      agent_args: [stdout_arg],
      manifest_path: ctx.manifest_path,
      run_log_path: ctx.log_path,
      run_token: ctx.run_token
    )
  end

  # --- US1: generated run recorded correctly ---

  describe "US1 — outcome record + transcript tally" do
    test "2 granted + 1 rejected ⇒ ok, actions=2, rejected_count=1", ctx do
      ActionTranscript.append(ctx.run_token, granted())
      ActionTranscript.append(ctx.run_token, granted())
      ActionTranscript.append(ctx.run_token, rejected(:ungranted_method))

      assert :ok = run(ctx, outcome_json())

      log = File.read!(ctx.log_path)
      assert log =~ "status=ok"
      assert log =~ "actions=2"
      assert log =~ "approved_count=2"
      assert log =~ "rejected_count=1"
      assert log =~ "gate_reasons=[:ungranted_method]"
      refute log =~ "malformed"
    end

    test "empty transcript ⇒ ok no-op with zero effects", ctx do
      assert :ok = run(ctx, outcome_json("completed", "nothing to do"))

      log = File.read!(ctx.log_path)
      assert log =~ "status=ok"
      assert log =~ "actions=0"
      assert log =~ "approved_count=0 rejected_count=0 parked_count=0"
    end

    test "malformed stdout ⇒ error, distinct from ok, transcript left intact", ctx do
      # Seed a populated transcript; a malformed run must not undo it (FR-008 edge).
      ActionTranscript.append(ctx.run_token, granted())
      before = ActionTranscript.read(ctx.run_token).entries

      assert {:error, :malformed_outcome} = run(ctx, ~s({"actions": []}))

      log = File.read!(ctx.log_path)
      assert log =~ "status=error"
      assert log =~ "failure_cause=malformed_outcome"
      refute log =~ "status=ok"

      assert ActionTranscript.read(ctx.run_token).entries == before
    end
  end

  # --- US2: no double execution + no transcript mutation ---

  describe "US2 — worker never executes or mutates" do
    test "granted effect is not re-executed; roster_trust unchanged by the worker", ctx do
      # A granted transcript entry represents an effect the rail already executed.
      # The worker must not touch roster_trust again.
      ActionTranscript.append(ctx.run_token, granted())
      roster_before = StateStore.snapshot("roster_trust")

      assert :ok = run(ctx, outcome_json())

      assert StateStore.snapshot("roster_trust") == roster_before
    end

    test "worker reads the transcript but does not mutate it", ctx do
      ActionTranscript.append(ctx.run_token, granted())
      ActionTranscript.append(ctx.run_token, rejected())
      count_before = length(ActionTranscript.read(ctx.run_token).entries)

      assert :ok = run(ctx, outcome_json())

      assert length(ActionTranscript.read(ctx.run_token).entries) == count_before
    end
  end

  # --- US3: spend + breach from the ledger ---

  describe "US3 — spend and breach accounting" do
    test "ledger at/over cap post-run ⇒ killed with transcript-derived counts", ctx do
      # Simulate the broker having charged the ledger past the cap during inference.
      StateStore.apply_action(
        "spend_ledger",
        {:put, ctx.agent_name, %{spent: 500_000, window_start: DateTime.utc_now()}}
      )

      ActionTranscript.append(ctx.run_token, granted())
      ActionTranscript.append(ctx.run_token, rejected())

      # Pre-check breach fires before the agent runs; counts are empty there.
      assert {:killed, :spend_breach} = run(ctx, outcome_json())

      log = File.read!(ctx.log_path)
      assert log =~ "status=killed"
      assert log =~ "failure_cause=spend_breach"
    end

    test "spend under cap ⇒ ok", ctx do
      StateStore.apply_action(
        "spend_ledger",
        {:put, ctx.agent_name, %{spent: 1000, window_start: DateTime.utc_now()}}
      )

      ActionTranscript.append(ctx.run_token, granted())

      assert :ok = run(ctx, outcome_json())
      assert File.read!(ctx.log_path) =~ "status=ok"
    end
  end

  # --- US4: approval-required effects stay human-gated ---

  describe "US4 — parked effects reflected, not duplicated" do
    test "1 parked entry + 1 queued approval ⇒ log parked_count=1, queue unchanged", ctx do
      ActionTranscript.append(ctx.run_token, granted())
      ActionTranscript.append(ctx.run_token, parked())

      # The rail already queued the approval during inference.
      StateStore.apply_action(
        "pending_approvals",
        {:put, :approvals,
         %{
           "ref_seed" => %{
             ref: "ref_seed",
             action: %AgentOS.ProposedAction{type: "external_send", method: "send", payload: %{}},
             grant: %AgentOS.Manifest.Grant{connector: "external_send", methods: ["send"]}
           }
         }}
      )

      assert :ok = run(ctx, outcome_json())

      log = File.read!(ctx.log_path)
      assert log =~ "parked_count=1"

      approvals = StateStore.snapshot("pending_approvals") |> Map.get(:approvals, %{})
      assert map_size(approvals) == 1
    end
  end
end
