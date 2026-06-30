defmodule AgentOS.ConformanceAuditorTest do
  use ExUnit.Case, async: false

  alias AgentOS.ConformanceAuditor
  alias AgentOS.ConformanceAuditor.RunRecord
  alias AgentOS.ConformanceAuditor.Verdict
  alias AgentOS.ConformanceAuditor.Flag

  setup do
    now = DateTime.utc_now()
    {:ok, now: now}
  end

  test "audit/2 returns :insufficient_data for empty or short trace", %{now: now} do
    # Empty trace
    v1 = ConformanceAuditor.audit([], "test purpose", now: now, window: 5, agent: "test_agent")
    assert v1.status == :insufficient_data
    assert v1.flags == []
    assert v1.agent == "test_agent"
    assert v1.computed_at == now

    # Short trace (fewer than window size)
    records = [
      %RunRecord{status: "ok", actions: 1},
      %RunRecord{status: "ok", actions: 1}
    ]

    v2 =
      ConformanceAuditor.audit(records, "test purpose", now: now, window: 5, agent: "test_agent")

    assert v2.status == :insufficient_data
    assert v2.flags == []
  end

  test "audit/2 returns :clean for trace >= window with no flags", %{now: now} do
    records = Enum.map(1..5, fn _ -> %RunRecord{status: "ok", actions: 1} end)

    v =
      ConformanceAuditor.audit(records, "test purpose", now: now, window: 5, agent: "test_agent")

    assert v.status == :clean
    assert v.flags == []
  end

  test "audit/2 keeps only the last N records (window selection)", %{now: now} do
    # Pass 6 records with window = 5.
    # The first record is malformed or has actions=0, but it should be discarded as it's outside the window.
    records = [
      # outside window
      %RunRecord{status: "ok", actions: 0},
      %RunRecord{status: "ok", actions: 1},
      %RunRecord{status: "ok", actions: 1},
      %RunRecord{status: "ok", actions: 1},
      %RunRecord{status: "ok", actions: 1},
      %RunRecord{status: "ok", actions: 1}
    ]

    v =
      ConformanceAuditor.audit(records, "test purpose", now: now, window: 5, agent: "test_agent")

    # If the first record was processed, the quiet streak would be affected or it might change state.
    # But since it's discarded, the last 5 records are all actions=1 (clean).
    assert v.status == :clean
    assert v.flags == []
  end

  alias AgentOS.StateStore

  test "run_pass/1 orchestrates reading, auditing, persisting, and alerting", %{now: now} do
    tmp_manifest =
      Path.join(System.tmp_dir!(), "mock_manifest_#{System.unique_integer([:positive])}.md")

    tmp_run_log =
      Path.join(System.tmp_dir!(), "mock_run_log_#{System.unique_integer([:positive])}.md")

    tmp_conformance_term =
      Path.join(System.tmp_dir!(), "mock_conformance_#{System.unique_integer([:positive])}.term")

    tmp_alerts =
      Path.join(System.tmp_dir!(), "mock_alerts_#{System.unique_integer([:positive])}.md")

    on_exit(fn ->
      File.rm(tmp_manifest)
      File.rm(tmp_run_log)
      File.rm(tmp_conformance_term)
      File.rm(tmp_alerts)
    end)

    File.write!(tmp_manifest, """
    ---
    purpose: "Testing the conformance auditor"
    owner: "admin"
    supervision: "daily"
    grants: []
    spend:
      cap: 1000
      window: "daily"
      on_breach: "kill"
    ---
    """)

    File.write!(tmp_run_log, """
    - [2026-06-30T10:00:00Z] status=ok actions=1 trigger=manual clean run
    - [2026-06-30T10:01:00Z] status=ok actions=1 trigger=manual another clean run
    """)

    # Start Registry and StateStore
    start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})
    start_supervised!({StateStore, name: "conformance", path: tmp_conformance_term, initial: %{}})

    # Run pass
    verdict1 =
      ConformanceAuditor.run_pass(
        manifest_path: tmp_manifest,
        run_log_path: tmp_run_log,
        window: 2,
        admin_alerts_path: tmp_alerts,
        now: now
      )

    assert verdict1.status == :clean
    assert verdict1.flags == []
    # Verify persisted
    agent_name = Path.basename(tmp_manifest, ".md")
    assert StateStore.snapshot("conformance")[agent_name] == verdict1
    # Verify no alert file created (no flags)
    refute File.exists?(tmp_alerts)
  end

  test "detect_escalated_flags/2 escalation logic" do
    f_health = %Flag{type: :quiet, severity: :health, description: "quiet"}
    _f_count = %Flag{type: :denied_approval, severity: :count, description: "denied"}
    _f_trip = %Flag{type: :gate_breach, severity: :tripwire, description: "breach"}

    # 1. Newly raised
    assert ConformanceAuditor.detect_escalated_flags([f_health], []) == [f_health]

    # 2. No change
    assert ConformanceAuditor.detect_escalated_flags([f_health], [f_health]) == []

    # 3. Escalated (severity went up)
    f_quiet_escalated = %{f_health | severity: :tripwire}

    assert ConformanceAuditor.detect_escalated_flags([f_quiet_escalated], [f_health]) == [
             f_quiet_escalated
           ]

    # 4. Cleared (not escalated)
    assert ConformanceAuditor.detect_escalated_flags([], [f_health]) == []
  end

  describe "User Story 1: Trust Flags" do
    test "gate-breach tripwire raises gate_breach flag (severity :tripwire)", %{now: now} do
      # 1. breached_count > 0
      records1 = [
        %RunRecord{status: "ok", actions: 1, breached_count: 1, gate_reasons: []}
      ]

      v1 =
        ConformanceAuditor.audit(records1, "test purpose",
          now: now,
          window: 5,
          agent: "test_agent"
        )

      assert v1.status == :flagged
      assert length(v1.flags) == 1
      f1 = Enum.at(v1.flags, 0)
      assert f1.type == :gate_breach
      assert f1.severity == :tripwire
      assert f1.description =~ "manifest-breach attempt recorded"

      # 2. non-empty gate_reasons
      records2 = [
        %RunRecord{
          status: "ok",
          actions: 1,
          breached_count: 0,
          gate_reasons: ["unauthorized_grant"]
        }
      ]

      v2 =
        ConformanceAuditor.audit(records2, "test purpose",
          now: now,
          window: 5,
          agent: "test_agent"
        )

      assert v2.status == :flagged
      assert length(v2.flags) == 1
      assert Enum.at(v2.flags, 0).type == :gate_breach

      # 3. clean trace ⇒ no flag
      records3 = [
        %RunRecord{status: "ok", actions: 1, breached_count: 0, gate_reasons: []}
      ]

      v3 =
        ConformanceAuditor.audit(records3, "test purpose",
          now: now,
          window: 5,
          agent: "test_agent"
        )

      assert v3.status == :insufficient_data
      assert v3.flags == []
    end

    test "denied-approval raises denied_approval flag (severity :count) after threshold", %{
      now: now
    } do
      # 3 denied approval-resume records, followed by a productive run, and prefixed by another productive run (length = 5 >= window = 5)
      records1 = [
        %RunRecord{status: "ok", actions: 1},
        %RunRecord{
          status: "ok",
          actions: 0,
          trigger: "approval-resume",
          note: "denied ref=ref_1"
        },
        %RunRecord{
          status: "ok",
          actions: 0,
          trigger: "approval-resume",
          note: "denied ref=ref_2"
        },
        %RunRecord{
          status: "ok",
          actions: 0,
          trigger: "approval-resume",
          note: "denied ref=ref_3"
        },
        %RunRecord{status: "ok", actions: 1}
      ]

      v1 =
        ConformanceAuditor.audit(records1, "test purpose",
          now: now,
          window: 5,
          agent: "test_agent",
          denied_threshold: 3
        )

      assert v1.status == :flagged
      assert length(v1.flags) == 1
      f1 = Enum.at(v1.flags, 0)
      assert f1.type == :denied_approval
      assert f1.severity == :count
      assert f1.description =~ "3 approval-required actions denied"

      # 2 denied approval-resume records, prefixed/suffixed (length = 5 >= window = 5)
      records2 = [
        %RunRecord{status: "ok", actions: 1},
        %RunRecord{status: "ok", actions: 1},
        %RunRecord{
          status: "ok",
          actions: 0,
          trigger: "approval-resume",
          note: "denied ref=ref_1"
        },
        %RunRecord{
          status: "ok",
          actions: 0,
          trigger: "approval-resume",
          note: "denied ref=ref_2"
        },
        %RunRecord{status: "ok", actions: 1}
      ]

      v2 =
        ConformanceAuditor.audit(records2, "test purpose",
          now: now,
          window: 5,
          agent: "test_agent",
          denied_threshold: 3
        )

      assert v2.status == :clean
      assert v2.flags == []
    end

    test "non-redundancy: rejected_count is never counted", %{now: now} do
      records = [
        %RunRecord{status: "ok", actions: 1, rejected_count: 5}
      ]

      v =
        ConformanceAuditor.audit(records, "test purpose",
          now: now,
          window: 5,
          agent: "test_agent",
          denied_threshold: 3
        )

      assert v.status == :insufficient_data
      assert v.flags == []
    end

    test "non-redundancy: other anomalies do not raise a flag", %{now: now} do
      records = [
        %RunRecord{status: "ok", actions: 1, items_in: 10, items_dropped: 1, trigger: "manual"}
      ]

      v =
        ConformanceAuditor.audit(records, "test purpose",
          now: now,
          window: 5,
          agent: "test_agent"
        )

      assert v.status == :insufficient_data
      assert v.flags == []
    end

    test "FLAG-ONLY invariant test for the trust path", %{now: now} do
      records = [
        %RunRecord{status: "ok", actions: 0, trigger: "approval-resume", note: "denied ref=1"},
        %RunRecord{status: "ok", actions: 0, trigger: "approval-resume", note: "denied ref=2"},
        %RunRecord{status: "ok", actions: 0, trigger: "approval-resume", note: "denied ref=3"}
      ]

      v =
        ConformanceAuditor.audit(records, "test purpose",
          now: now,
          window: 5,
          agent: "test_agent",
          denied_threshold: 3
        )

      refute Map.has_key?(v, :gate_status)
      refute Map.has_key?(v, :allowed)
      refute Map.has_key?(v, :deploy)
      assert %Verdict{} = v
    end

    test "run_pass/1 alerts on newly raised gate-breach flag but not on subsequent runs", %{
      now: now
    } do
      tmp_manifest =
        Path.join(System.tmp_dir!(), "mock_manifest_#{System.unique_integer([:positive])}.md")

      tmp_run_log =
        Path.join(System.tmp_dir!(), "mock_run_log_#{System.unique_integer([:positive])}.md")

      tmp_conformance_term =
        Path.join(
          System.tmp_dir!(),
          "mock_conformance_#{System.unique_integer([:positive])}.term"
        )

      tmp_alerts =
        Path.join(System.tmp_dir!(), "mock_alerts_#{System.unique_integer([:positive])}.md")

      on_exit(fn ->
        File.rm(tmp_manifest)
        File.rm(tmp_run_log)
        File.rm(tmp_conformance_term)
        File.rm(tmp_alerts)
      end)

      File.write!(tmp_manifest, """
      ---
      purpose: "Testing alerts"
      owner: "admin"
      supervision: "daily"
      grants: []
      spend:
        cap: 1000
        window: "daily"
        on_breach: "kill"
      ---
      """)

      File.write!(tmp_run_log, """
      - [2026-06-30T10:00:00Z] status=ok actions=1 breached_count=1 gate_reasons=[] some breached action
      """)

      start_supervised!({Registry, keys: :unique, name: AgentOS.StateStoreRegistry})

      start_supervised!(
        {StateStore, name: "conformance", path: tmp_conformance_term, initial: %{}}
      )

      # Run pass 1: should alert because gate-breach is newly raised
      verdict1 =
        ConformanceAuditor.run_pass(
          manifest_path: tmp_manifest,
          run_log_path: tmp_run_log,
          window: 1,
          admin_alerts_path: tmp_alerts,
          now: now
        )

      assert verdict1.status == :flagged
      assert length(verdict1.flags) == 1
      assert File.exists?(tmp_alerts)
      alerts_content1 = File.read!(tmp_alerts)
      assert alerts_content1 =~ "flag=gate_breach"

      # Run pass 2: same trace, should NOT alert again
      File.rm(tmp_alerts)

      verdict2 =
        ConformanceAuditor.run_pass(
          manifest_path: tmp_manifest,
          run_log_path: tmp_run_log,
          window: 1,
          admin_alerts_path: tmp_alerts,
          now: now
        )

      assert verdict2.status == :flagged
      refute File.exists?(tmp_alerts)
    end
  end

  describe "User Story 2: Health Flags" do
    test "quiet flag raises on trailing actions=0 streak >= quiet_streak", %{now: now} do
      # Streak of 3 runs with actions=0 at the end of the window
      records1 = [
        %RunRecord{status: "ok", actions: 1},
        %RunRecord{status: "ok", actions: 0},
        %RunRecord{status: "ok", actions: 0},
        %RunRecord{status: "ok", actions: 0}
      ]

      v1 =
        ConformanceAuditor.audit(records1, "test purpose",
          now: now,
          window: 4,
          quiet_streak: 3,
          agent: "test_agent"
        )

      assert v1.status == :flagged
      assert length(v1.flags) == 1
      f1 = Enum.at(v1.flags, 0)
      assert f1.type == :quiet
      assert f1.severity == :health
      assert f1.description =~ "No action in 3 consecutive runs"

      # Recent productive run at the end clears the streak ⇒ no flag
      records2 = [
        %RunRecord{status: "ok", actions: 0},
        %RunRecord{status: "ok", actions: 0},
        %RunRecord{status: "ok", actions: 0},
        %RunRecord{status: "ok", actions: 1}
      ]

      v2 =
        ConformanceAuditor.audit(records2, "test purpose",
          now: now,
          window: 4,
          quiet_streak: 3,
          agent: "test_agent"
        )

      assert v2.status == :clean
      assert v2.flags == []
    end

    test "sick flag raises on status=alert in window", %{now: now} do
      # status=alert in window
      records = [
        %RunRecord{status: "ok", actions: 1},
        %RunRecord{status: "alert", actions: 1},
        %RunRecord{status: "ok", actions: 1}
      ]

      v =
        ConformanceAuditor.audit(records, "test purpose",
          now: now,
          window: 3,
          agent: "test_agent"
        )

      assert v.status == :flagged
      assert length(v.flags) == 1
      f = Enum.at(v.flags, 0)
      assert f.type == :sick
      assert f.severity == :health
      assert f.description =~ "alert condition recorded"
    end

    test "sick flag raises on strictly rising input drop share", %{now: now} do
      # latest record drops strictly greater share of input than previous (with items_dropped > 0)
      # Previous: 2/10 dropped (20%)
      # Latest: 3/10 dropped (30%)
      records1 = [
        %RunRecord{status: "ok", actions: 1, items_in: 10, items_dropped: 2},
        %RunRecord{status: "ok", actions: 1, items_in: 10, items_dropped: 3}
      ]

      v1 =
        ConformanceAuditor.audit(records1, "test purpose",
          now: now,
          window: 2,
          agent: "test_agent"
        )

      assert v1.status == :flagged
      assert length(v1.flags) == 1
      f = Enum.at(v1.flags, 0)
      assert f.type == :sick
      assert f.severity == :health
      assert f.description =~ "strictly-rising load shedding detected"

      # Falling share: 2/10 (20%) -> 1/10 (10%) ⇒ no flag
      records2 = [
        %RunRecord{status: "ok", actions: 1, items_in: 10, items_dropped: 2},
        %RunRecord{status: "ok", actions: 1, items_in: 10, items_dropped: 1}
      ]

      v2 =
        ConformanceAuditor.audit(records2, "test purpose",
          now: now,
          window: 2,
          agent: "test_agent"
        )

      assert v2.status == :clean
      assert v2.flags == []

      # Equal share: 2/10 (20%) -> 2/10 (20%) ⇒ no flag
      records3 = [
        %RunRecord{status: "ok", actions: 1, items_in: 10, items_dropped: 2},
        %RunRecord{status: "ok", actions: 1, items_in: 10, items_dropped: 2}
      ]

      v3 =
        ConformanceAuditor.audit(records3, "test purpose",
          now: now,
          window: 2,
          agent: "test_agent"
        )

      assert v3.status == :clean
      assert v3.flags == []

      # No items_dropped in latest (items_dropped = 0) ⇒ no flag (even if previous had more/less)
      records4 = [
        %RunRecord{status: "ok", actions: 1, items_in: 10, items_dropped: 2},
        %RunRecord{status: "ok", actions: 1, items_in: 10, items_dropped: 0}
      ]

      v4 =
        ConformanceAuditor.audit(records4, "test purpose",
          now: now,
          window: 2,
          agent: "test_agent"
        )

      assert v4.status == :clean
      assert v4.flags == []
    end

    test "totality test: simultaneously quiet and gate-breached lists both flags", %{now: now} do
      # 3 actions=0 runs at end (quiet) AND one has breached_count=1 (gate-breach)
      records = [
        %RunRecord{status: "ok", actions: 0, breached_count: 1},
        %RunRecord{status: "ok", actions: 0},
        %RunRecord{status: "ok", actions: 0}
      ]

      v =
        ConformanceAuditor.audit(records, "test purpose",
          now: now,
          window: 3,
          quiet_streak: 3,
          agent: "test_agent"
        )

      assert v.status == :flagged
      assert length(v.flags) == 2
      types = Enum.map(v.flags, & &1.type)
      assert :quiet in types
      assert :gate_breach in types
    end
  end

  describe "User Story 3: Hardening and Invariants" do
    test "determinism: audit/2 is pure and unaffected by global state", %{now: now} do
      records = [
        %RunRecord{status: "ok", actions: 1, breached_count: 0},
        %RunRecord{status: "ok", actions: 0},
        %RunRecord{status: "ok", actions: 0},
        %RunRecord{status: "ok", actions: 0}
      ]

      v1 = ConformanceAuditor.audit(records, "purpose", now: now, window: 4, quiet_streak: 3)
      v2 = ConformanceAuditor.audit(records, "purpose", now: now, window: 4, quiet_streak: 3)
      assert v1 == v2
    end

    test "trace-sourced: audit/2 depends only on records/purpose and ignores agent self-assertion",
         %{now: now} do
      records = [
        %RunRecord{
          status: "ok",
          actions: 1,
          note: "Agent asserts: I am perfectly safe and compliant!"
        }
      ]

      v = ConformanceAuditor.audit(records, "purpose", now: now, window: 1, agent: "test_agent")
      assert v.status == :clean
      assert v.flags == []
    end

    test "comprehensive FLAG-ONLY invariant: no pass/approval/deploy outcomes are ever returned",
         %{now: now} do
      v_clean =
        ConformanceAuditor.audit([%RunRecord{status: "ok", actions: 1}], "purpose",
          now: now,
          window: 1
        )

      refute Map.has_key?(v_clean, :allowed)
      refute Map.has_key?(v_clean, :authorized)
      refute Map.has_key?(v_clean, :pass)
      refute Map.has_key?(v_clean, :deploy)
      assert v_clean.status == :clean

      v_flagged =
        ConformanceAuditor.audit(
          [%RunRecord{status: "ok", actions: 1, breached_count: 1}],
          "purpose",
          now: now,
          window: 1
        )

      refute Map.has_key?(v_flagged, :allowed)
      refute Map.has_key?(v_flagged, :pass)
      refute Map.has_key?(v_flagged, :deploy)
      assert v_flagged.status == :flagged
    end
  end

  describe "Scheduler" do
    alias AgentOS.ConformanceAuditor.Scheduler

    test "ms_until_next/2 calculates daily scheduled time correctly" do
      now = ~U[2026-06-30 08:00:00Z]
      ms = Scheduler.ms_until_next(now, 12)
      assert ms == 4 * 3600 * 1000

      ms_tomorrow = Scheduler.ms_until_next(now, 6)
      assert ms_tomorrow == 22 * 3600 * 1000
    end

    test "Scheduler reschedules and calls run_fn on fire" do
      test_pid = self()
      run_fn = fn -> send(test_pid, :fired) end

      {:ok, pid} = start_supervised({Scheduler, run_fn: run_fn, run_hour: 12})
      send(pid, :fire)

      assert_receive :fired, 1000
    end
  end

  describe "Edge Cases" do
    test "no-history agent returns :insufficient_data without error or spurious flags", %{
      now: now
    } do
      v = ConformanceAuditor.audit([], "purpose", now: now, window: 20)
      assert v.status == :insufficient_data
      assert v.flags == []
    end

    test "short trace still evaluates the gate-breach tripwire while rate/streak signals report insufficient data",
         %{now: now} do
      # 1. Short trace with gate breach ⇒ status: :flagged, flags: [:gate_breach]
      records1 = [
        %RunRecord{status: "ok", actions: 1, breached_count: 1}
      ]

      v1 = ConformanceAuditor.audit(records1, "purpose", now: now, window: 20)
      assert v1.status == :flagged
      assert length(v1.flags) == 1
      assert Enum.at(v1.flags, 0).type == :gate_breach

      # 2. Short trace with quiet streak of 3, window of 5 ⇒ rate/streak signals do NOT raise, status is :insufficient_data
      records2 = [
        %RunRecord{status: "ok", actions: 0},
        %RunRecord{status: "ok", actions: 0},
        %RunRecord{status: "ok", actions: 0}
      ]

      v2 = ConformanceAuditor.audit(records2, "purpose", now: now, window: 5, quiet_streak: 3)
      assert v2.status == :insufficient_data
      assert v2.flags == []
    end

    test "flag clearing: a trust flag (gate-breach) present in one verdict disappears once the breach record leaves the window",
         %{now: now} do
      # 1. Breach record within window size 3
      records = [
        %RunRecord{status: "ok", actions: 1, breached_count: 1},
        %RunRecord{status: "ok", actions: 1},
        %RunRecord{status: "ok", actions: 1}
      ]

      v1 = ConformanceAuditor.audit(records, "purpose", now: now, window: 3)
      assert v1.status == :flagged
      assert Enum.any?(v1.flags, &(&1.type == :gate_breach))

      # 2. Breach record aged out (outside window size 3)
      records_new = records ++ [%RunRecord{status: "ok", actions: 1}]
      v2 = ConformanceAuditor.audit(records_new, "purpose", now: now, window: 3)
      assert v2.status == :clean
      refute Enum.any?(v2.flags, &(&1.type == :gate_breach))
    end
  end
end
