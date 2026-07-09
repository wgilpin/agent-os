defmodule AgentOS.ProvisionerTest do
  use ExUnit.Case, async: false

  alias AgentOS.Provisioner

  setup do
    original_config = Application.get_env(:agent_os, :agent)
    mounts = AgentOS.TestHelper.start_mounts!()

    on_exit(fn ->
      if original_config do
        Application.put_env(:agent_os, :agent, original_config)
      else
        Application.delete_env(:agent_os, :agent)
      end
    end)

    {:ok, Map.put(mounts, :original_config, original_config)}
  end

  defp seed_pass_verdicts(agent_name, code_hash \\ "") do
    :ok =
      AgentOS.StateStore.apply_action(
        "judge_results",
        {:put, agent_name, %{status: :pass, code_hash: code_hash}}
      )

    :ok =
      AgentOS.StateStore.apply_action(
        "security_review_results",
        {:put, agent_name,
         %AgentOS.Pipeline.Stage5.Verdict{
           status: :pass,
           reasoning: "ok",
           timestamp: DateTime.utc_now(),
           code_hash: code_hash
         }}
      )
  end

  defp create_temp_agent(agent_name) do
    temp_dir = Path.join(System.tmp_dir!(), "agents_#{System.unique_integer([:positive])}")
    agent_dir = Path.join(temp_dir, agent_name)
    File.mkdir_p!(agent_dir)
    File.write!(Path.join(agent_dir, "main.py"), "main")
    File.write!(Path.join(agent_dir, "models.py"), "models")

    hash = :crypto.hash(:sha256, "main\nmodels") |> Base.encode16()

    on_exit(fn ->
      try do
        File.rm_rf!(temp_dir)
      rescue
        _ -> :ok
      end
    end)

    {[spec_dir: temp_dir], hash}
  end

  test "agent_config/0 returns a map with all hard-wired keys" do
    config = Provisioner.agent_config()
    assert is_map(config)
    assert config.manifest_path == "test/fixtures/manifests/discovery.md"
    assert config.agent_cmd == "docker"
    assert config.agent_args == []
    assert config.tz == "Etc/UTC"
    assert config.run_hour == 7

    assert config.grants == [
             %{connector: "kv_append", recipients: nil, methods: ["append"]},
             %{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}
           ]

    assert config.spend == %{cap: 500_000, window: :daily, on_breach: :kill}
  end

  test "check_drift/0 returns :ok when config matches manifest" do
    assert Provisioner.check_drift() == :ok
  end

  test "check_drift/0 returns {:drift, fields} when grants drift" do
    config = Application.get_env(:agent_os, :agent)

    updated_config =
      Keyword.put(config, :grants, [%{connector: "kv_append", recipients: nil, methods: []}])

    Application.put_env(:agent_os, :agent, updated_config)

    assert {:drift, [:grants]} = Provisioner.check_drift()
  end

  test "check_drift/0 returns {:drift, fields} when spend drifts" do
    config = Application.get_env(:agent_os, :agent)
    updated_config = Keyword.put(config, :spend, %{cap: 999, window: :daily, on_breach: :kill})
    Application.put_env(:agent_os, :agent, updated_config)

    assert {:drift, [:spend]} = Provisioner.check_drift()
  end

  test "check_drift/0 returns {:drift, fields} with multiple mismatched fields" do
    config = Application.get_env(:agent_os, :agent)

    updated_config =
      config
      |> Keyword.put(:grants, [])
      |> Keyword.put(:spend, %{cap: 100, window: :daily, on_breach: :kill})

    Application.put_env(:agent_os, :agent, updated_config)

    assert {:drift, [:grants, :spend]} = Provisioner.check_drift()
  end

  test "deploy/3 always_review blocks and parks deployment", %{
    conformance_path: _c,
    provenance_path: _p
  } do
    temp_manifest =
      Path.join(
        System.tmp_dir!(),
        "deploy_always_review_#{System.unique_integer([:positive])}.md"
      )

    File.write!(temp_manifest, """
    ---
    purpose: "test always review"
    grants: []
    spend:
      cap: 50000
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    # Always review
    """)

    on_exit(fn -> File.rm(temp_manifest) end)

    agent_name = Path.basename(temp_manifest, ".md")
    {opts, code_hash} = create_temp_agent(agent_name)
    seed_pass_verdicts(agent_name, code_hash)

    assert {:blocked, ref} = Provisioner.deploy(temp_manifest, :always_review, opts)
    assert String.starts_with?(ref, "ref_deploy_")

    pending = AgentOS.StateStore.snapshot("pending_approvals")
    approvals = Map.get(pending, :approvals, %{})
    assert Map.has_key?(approvals, ref)
    stored = Map.get(approvals, ref)
    assert stored.action.type == "deploy"
    assert stored.action.recipient == Path.basename(temp_manifest, ".md")
  end

  test "envelope_predicate?/2 classifications" do
    in_env_manifest = %AgentOS.Manifest{
      purpose: "test",
      owner: "human",
      supervision: "none",
      grants: [],
      spend: %AgentOS.Manifest.Spend{cap: 50000, window: :daily, on_breach: :kill}
    }

    assert Provisioner.envelope_predicate?(in_env_manifest)

    out_spend_manifest = %AgentOS.Manifest{
      purpose: "test",
      owner: "human",
      supervision: "none",
      grants: [],
      spend: %AgentOS.Manifest.Spend{cap: 150_000, window: :daily, on_breach: :kill}
    }

    assert not Provisioner.envelope_predicate?(out_spend_manifest)

    original_registry = Application.get_env(:agent_os, :connector_registry)

    mock_registry = %{
      "safe_read" => %{
        name: "safe_read",
        mutating?: false,
        requires_deploy_consent?: false,
        requires_runtime_approval?: false,
        credential: nil,
        cost: 0
      },
      "unsafe_write" => %{
        name: "unsafe_write",
        mutating?: true,
        requires_deploy_consent?: true,
        requires_runtime_approval?: true,
        credential: :token,
        cost: 2000
      }
    }

    Application.put_env(:agent_os, :connector_registry, mock_registry)

    on_exit(fn ->
      if original_registry,
        do: Application.put_env(:agent_os, :connector_registry, original_registry),
        else: Application.delete_env(:agent_os, :connector_registry)
    end)

    out_egress_manifest = %AgentOS.Manifest{
      purpose: "test",
      owner: "human",
      supervision: "none",
      grants: [%AgentOS.Manifest.Grant{connector: "unsafe_write"}],
      spend: %AgentOS.Manifest.Spend{cap: 50000, window: :daily, on_breach: :kill}
    }

    assert not Provisioner.envelope_predicate?(out_egress_manifest)
  end

  test "deploy/3 review_if_risky conditional checks" do
    original_registry = Application.get_env(:agent_os, :connector_registry)

    mock_registry = %{
      "safe_read" => %{
        name: "safe_read",
        mutating?: false,
        requires_deploy_consent?: false,
        requires_runtime_approval?: false,
        credential: nil,
        cost: 0
      },
      "unsafe_write" => %{
        name: "unsafe_write",
        mutating?: true,
        requires_deploy_consent?: true,
        requires_runtime_approval?: true,
        credential: :token,
        cost: 2000
      }
    }

    Application.put_env(:agent_os, :connector_registry, mock_registry)

    on_exit(fn ->
      if original_registry,
        do: Application.put_env(:agent_os, :connector_registry, original_registry),
        else: Application.delete_env(:agent_os, :connector_registry)
    end)

    safe_manifest = Path.join(System.tmp_dir!(), "safe_#{System.unique_integer([:positive])}.md")

    File.write!(safe_manifest, """
    ---
    purpose: "safe"
    grants:
      - connector: "safe_read"
    spend:
      cap: 50000
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    """)

    on_exit(fn -> File.rm(safe_manifest) end)

    unsafe_manifest =
      Path.join(System.tmp_dir!(), "unsafe_#{System.unique_integer([:positive])}.md")

    File.write!(unsafe_manifest, """
    ---
    purpose: "unsafe"
    grants:
      - connector: "unsafe_write"
    spend:
      cap: 50000
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    """)

    on_exit(fn -> File.rm(unsafe_manifest) end)

    safe_agent = Path.basename(safe_manifest, ".md")
    unsafe_agent = Path.basename(unsafe_manifest, ".md")

    {safe_opts, safe_hash} = create_temp_agent(safe_agent)
    {unsafe_opts, unsafe_hash} = create_temp_agent(unsafe_agent)

    seed_pass_verdicts(safe_agent, safe_hash)
    seed_pass_verdicts(unsafe_agent, unsafe_hash)

    assert {:ok, :skipped_in_envelope} =
             Provisioner.deploy(safe_manifest, :review_if_risky, safe_opts)

    assert {:blocked, ref} = Provisioner.deploy(unsafe_manifest, :review_if_risky, unsafe_opts)
    assert String.starts_with?(ref, "ref_deploy_")

    safe_agent = Path.basename(safe_manifest, ".md")

    verdict = %AgentOS.ConformanceAuditor.Verdict{
      agent: safe_agent,
      status: :flagged,
      flags: [
        %AgentOS.ConformanceAuditor.Flag{
          type: :gate_breach,
          severity: :tripwire,
          description: "breach"
        }
      ],
      computed_at: DateTime.utc_now()
    }

    AgentOS.StateStore.apply_action("conformance", {:put, safe_agent, verdict})

    File.write!(safe_manifest, """
    ---
    purpose: "safe modified"
    grants:
      - connector: "safe_read"
    spend:
      cap: 50000
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    """)

    assert {:blocked, _ref2} = Provisioner.deploy(safe_manifest, :review_if_risky, safe_opts)
  end

  test "deploy/3 dangerously_skip_review proceeds immediately" do
    original_registry = Application.get_env(:agent_os, :connector_registry)

    mock_registry = %{
      "unsafe_write" => %{
        name: "unsafe_write",
        mutating?: true,
        requires_deploy_consent?: true,
        requires_runtime_approval?: true,
        credential: :token,
        cost: 2000
      }
    }

    Application.put_env(:agent_os, :connector_registry, mock_registry)

    on_exit(fn ->
      if original_registry,
        do: Application.put_env(:agent_os, :connector_registry, original_registry),
        else: Application.delete_env(:agent_os, :connector_registry)
    end)

    unsafe_manifest =
      Path.join(System.tmp_dir!(), "unsafe_skip_#{System.unique_integer([:positive])}.md")

    File.write!(unsafe_manifest, """
    ---
    purpose: "unsafe"
    grants:
      - connector: "unsafe_write"
    spend:
      cap: 150000
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    """)

    on_exit(fn -> File.rm(unsafe_manifest) end)

    agent_name = Path.basename(unsafe_manifest, ".md")
    {opts, code_hash} = create_temp_agent(agent_name)
    seed_pass_verdicts(agent_name, code_hash)

    assert {:ok, :dangerously_skipped} =
             Provisioner.deploy(unsafe_manifest, :dangerously_skip_review, opts)
  end

  test "deploy/3 hash check bypasses block on second deployment" do
    temp_manifest =
      Path.join(System.tmp_dir!(), "hash_check_#{System.unique_integer([:positive])}.md")

    File.write!(temp_manifest, """
    ---
    purpose: "test"
    grants: []
    spend:
      cap: 50000
      window: "daily"
      on_breach: "kill"
    owner: "human"
    supervision: "none"
    ---
    """)

    on_exit(fn -> File.rm(temp_manifest) end)

    agent_name = Path.basename(temp_manifest, ".md")
    {opts, code_hash} = create_temp_agent(agent_name)
    seed_pass_verdicts(agent_name, code_hash)

    assert {:blocked, _ref} = Provisioner.deploy(temp_manifest, :always_review, opts)

    agent_name = Path.basename(temp_manifest, ".md")
    hash = Provisioner.manifest_hash(temp_manifest)
    :ok = Provisioner.record_provenance(agent_name, :reviewed_human, hash)

    assert {:ok, :reviewed_human} = Provisioner.deploy(temp_manifest, :always_review, opts)
  end

  describe "deploy-on-green new gating rules" do
    test "US1: green path under all three review modes" do
      temp_manifest =
        Path.join(System.tmp_dir!(), "green_us1_#{System.unique_integer([:positive])}.md")

      File.write!(temp_manifest, """
      ---
      purpose: "test green"
      grants: []
      spend:
        cap: 50000
        window: "daily"
        on_breach: "kill"
      owner: "human"
      supervision: "none"
      ---
      """)

      on_exit(fn -> File.rm(temp_manifest) end)
      agent_name = Path.basename(temp_manifest, ".md")
      {opts, hash} = create_temp_agent(agent_name)
      seed_pass_verdicts(agent_name, hash)

      # 1. always-review blocks
      assert {:blocked, ref} = Provisioner.deploy(temp_manifest, :always_review, opts)
      assert String.starts_with?(ref, "ref_deploy_")
      provenance = AgentOS.StateStore.snapshot("provenance")[agent_name]
      assert provenance.status == :blocked
      assert provenance.judge_verdict == :pass
      assert provenance.security_verdict == :pass
      assert provenance.failure_reason == nil

      # Reset provenance to test next modes
      AgentOS.StateStore.apply_action("provenance", {:delete_in, [agent_name]})

      # 2. review-if-risky (safe manifest -> skipped_in_envelope)
      assert {:ok, :skipped_in_envelope} =
               Provisioner.deploy(temp_manifest, :review_if_risky, opts)

      provenance = AgentOS.StateStore.snapshot("provenance")[agent_name]
      assert provenance.status == :skipped_in_envelope

      # Reset provenance
      AgentOS.StateStore.apply_action("provenance", {:delete_in, [agent_name]})

      # 3. dangerously-skip-review proceeds automatically
      assert {:ok, :dangerously_skipped} =
               Provisioner.deploy(temp_manifest, :dangerously_skip_review, opts)

      provenance = AgentOS.StateStore.snapshot("provenance")[agent_name]
      assert provenance.status == :dangerously_skipped
    end

    test "US2: red path failure cases" do
      temp_manifest =
        Path.join(System.tmp_dir!(), "fail_us2_#{System.unique_integer([:positive])}.md")

      File.write!(temp_manifest, """
      ---
      purpose: "test fail"
      grants: []
      spend:
        cap: 50000
        window: "daily"
        on_breach: "kill"
      owner: "human"
      supervision: "none"
      ---
      """)

      on_exit(fn -> File.rm(temp_manifest) end)
      agent_name = Path.basename(temp_manifest, ".md")
      {opts, hash} = create_temp_agent(agent_name)

      # 1. Missing verdict entirely
      assert {:error, {:gate_failed, :missing_verdict}} =
               Provisioner.deploy(temp_manifest, :always_review, opts)

      provenance = AgentOS.StateStore.snapshot("provenance")[agent_name]
      assert provenance.status == :failed
      assert provenance.failure_reason == :missing_verdict

      # 2. Stale verdict (mismatched code hash)
      seed_pass_verdicts(agent_name, "DIFFERENT_HASH")

      assert {:error, {:gate_failed, :stale_verdict}} =
               Provisioner.deploy(temp_manifest, :always_review, opts)

      provenance = AgentOS.StateStore.snapshot("provenance")[agent_name]
      assert provenance.status == :failed
      assert provenance.failure_reason == :stale_verdict

      # 3. Judge fail, security review pass
      :ok =
        AgentOS.StateStore.apply_action(
          "judge_results",
          {:put, agent_name, %{status: :fail, code_hash: hash}}
        )

      :ok =
        AgentOS.StateStore.apply_action(
          "security_review_results",
          {:put, agent_name,
           %AgentOS.Pipeline.Stage5.Verdict{
             status: :pass,
             reasoning: "ok",
             timestamp: DateTime.utc_now(),
             code_hash: hash
           }}
        )

      assert {:error, {:gate_failed, :judge_failed}} =
               Provisioner.deploy(temp_manifest, :always_review, opts)

      provenance = AgentOS.StateStore.snapshot("provenance")[agent_name]
      assert provenance.status == :failed
      assert provenance.failure_reason == :judge_failed

      # 4. Judge pass, security review fail
      :ok =
        AgentOS.StateStore.apply_action(
          "judge_results",
          {:put, agent_name, %{status: :pass, code_hash: hash}}
        )

      :ok =
        AgentOS.StateStore.apply_action(
          "security_review_results",
          {:put, agent_name,
           %AgentOS.Pipeline.Stage5.Verdict{
             status: :fail,
             reasoning: "bad",
             timestamp: DateTime.utc_now(),
             code_hash: hash
           }}
        )

      assert {:error, {:gate_failed, :security_review_failed}} =
               Provisioner.deploy(temp_manifest, :always_review, opts)

      provenance = AgentOS.StateStore.snapshot("provenance")[agent_name]
      assert provenance.status == :failed
      assert provenance.failure_reason == :security_review_failed

      # 5. Judge fail, security review fail
      :ok =
        AgentOS.StateStore.apply_action(
          "judge_results",
          {:put, agent_name, %{status: :fail, code_hash: hash}}
        )

      :ok =
        AgentOS.StateStore.apply_action(
          "security_review_results",
          {:put, agent_name,
           %AgentOS.Pipeline.Stage5.Verdict{
             status: :fail,
             reasoning: "bad",
             timestamp: DateTime.utc_now(),
             code_hash: hash
           }}
        )

      assert {:error, {:gate_failed, :both_failed}} =
               Provisioner.deploy(temp_manifest, :always_review, opts)

      provenance = AgentOS.StateStore.snapshot("provenance")[agent_name]
      assert provenance.status == :failed
      assert provenance.failure_reason == :both_failed
    end
  end
end
