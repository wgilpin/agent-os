defmodule AgentOS.Manifest.ProjectionTest do
  use ExUnit.Case, async: true

  alias AgentOS.ElicitedSpec
  alias AgentOS.Manifest
  alias AgentOS.Manifest.Grant
  alias AgentOS.Manifest.Spend
  alias AgentOS.Manifest.Projection

  test "rejects a non-positive spend cap (inert-agent guard)" do
    # A cap of 0 blocks every inference and connector call at the spend pre-check;
    # projection must refuse loudly instead of building an agent that can never act.
    spec = %ElicitedSpec{
      purpose: "Send the local time to Discord in French words",
      capabilities: ["discord_notify"],
      boundaries: %{egress_domains: [], target_locations: []},
      spend_limits: %{dollar_cap: 0.0, token_limit: 50_000},
      confirmed: true
    }

    assert {:error, :non_positive_spend_cap} = Projection.project(spec)
  end

  test "projects a valid confirmed ElicitedSpec successfully" do
    spec = %ElicitedSpec{
      purpose: "Surface content from recruiter emails",
      capabilities: ["kv_append", "external_send"],
      boundaries: %{
        egress_domains: ["owner-inbox"],
        target_locations: []
      },
      spend_limits: %{dollar_cap: 0.50, token_limit: 0},
      confirmed: true
    }

    assert {:ok, %Manifest{} = manifest} = Projection.project(spec)

    assert manifest.purpose == "Surface content from recruiter emails"
    assert manifest.owner == "human"
    assert manifest.supervision == "restart-once-and-alert"
    assert manifest.triggers == []
    assert manifest.mounts == []

    # Grants
    assert length(manifest.grants) == 2
    [grant1, grant2] = manifest.grants

    assert %Grant{connector: "kv_append", recipients: nil, methods: ["append"]} = grant1

    assert %Grant{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]} =
             grant2

    # Spend
    assert %Spend{cap: 500_000, window: :daily, on_breach: :kill} = manifest.spend

    # Serialization test
    markdown = Projection.serialize(manifest)
    assert markdown =~ "purpose: \"Surface content from recruiter emails\""
    assert markdown =~ "connector: kv_append"
    assert markdown =~ "methods: [\"append\"]"
    assert markdown =~ "connector: external_send"
    assert markdown =~ "recipients: [\"owner-inbox\"]"
    assert markdown =~ "methods: [\"send\"]"
    assert markdown =~ "cap: 500000"
    assert markdown =~ "window: daily"
    assert markdown =~ "on_breach: kill"
    assert markdown =~ "owner: human"
    assert markdown =~ "supervision: restart-once-and-alert"

    # Write test
    tmp_path =
      Path.join(System.tmp_dir!(), "projected_manifest_#{System.unique_integer([:positive])}.md")

    assert :ok = Projection.write(manifest, tmp_path)
    assert File.exists?(tmp_path)
    on_exit(fn -> File.rm(tmp_path) end)

    assert {:ok, %Manifest{} = loaded_manifest} = Manifest.load(tmp_path)
    assert loaded_manifest.purpose == manifest.purpose
    assert loaded_manifest.spend == manifest.spend
    assert length(loaded_manifest.grants) == 2
  end

  test "projects and round-trips all trigger types including startup" do
    triggers = [
      %{type: :startup},
      %{type: :time, at: "07:00"},
      %{type: :event, name: "approval_received"},
      %{type: :message}
    ]

    spec = %ElicitedSpec{
      purpose: "send a Discord message containing the local machine's time upon loading",
      capabilities: ["kv_append"],
      spend_limits: %{dollar_cap: 0.10, token_limit: 0},
      triggers: triggers,
      confirmed: true
    }

    assert {:ok, %Manifest{} = manifest} = Projection.project(spec)
    assert manifest.triggers == triggers

    markdown = Projection.serialize(manifest)
    assert markdown =~ "- type: startup"
    assert markdown =~ "- type: time"
    assert markdown =~ "at: \"07:00\""
    assert markdown =~ "- type: event"
    assert markdown =~ "name: \"approval_received\""
    assert markdown =~ "- type: message"

    tmp_path =
      Path.join(System.tmp_dir!(), "projected_triggers_#{System.unique_integer([:positive])}.md")

    assert :ok = Projection.write(manifest, tmp_path)
    on_exit(fn -> File.rm(tmp_path) end)

    assert {:ok, %Manifest{} = loaded} = Manifest.load(tmp_path)
    assert loaded.triggers == triggers
  end

  test "serialize raises descriptively on an unsupported trigger type" do
    spec = %ElicitedSpec{
      purpose: "p",
      capabilities: ["kv_append"],
      spend_limits: %{dollar_cap: 0.10, token_limit: 0},
      triggers: [%{type: :webhook}],
      confirmed: true
    }

    assert {:ok, manifest} = Projection.project(spec)

    assert_raise RuntimeError, ~r/Unsupported trigger type/, fn ->
      Projection.serialize(manifest)
    end
  end

  test "rejects an unconfirmed spec" do
    spec = %ElicitedSpec{
      purpose: "Surface content from recruiter emails",
      capabilities: ["kv_append"],
      spend_limits: %{dollar_cap: 0.50, token_limit: 0},
      confirmed: false
    }

    assert {:error, :not_confirmed} = Projection.project(spec)
  end

  test "renders consent view from manifest" do
    spec = %ElicitedSpec{
      purpose: "Surface content from recruiter emails",
      capabilities: ["kv_append", "external_send"],
      boundaries: %{
        egress_domains: ["owner-inbox"],
        target_locations: []
      },
      spend_limits: %{dollar_cap: 0.50, token_limit: 0},
      confirmed: true
    }

    assert {:ok, manifest} = Projection.project(spec)
    consent = Projection.consent_view(manifest)

    assert consent =~ "CAPABILITIES:"
    assert consent =~ "WRITE TO YOUR LOCAL STATE STORE"
    assert consent =~ "[EXTERNAL] SEND MESSAGES OUT TO EXTERNAL RECIPIENTS"
    assert consent =~ "owner-inbox"
  end

  test "rejects spec with missing purpose, empty capabilities, or unknown capability" do
    # Missing/empty purpose
    spec1 = %ElicitedSpec{
      purpose: "",
      capabilities: ["kv_append"],
      spend_limits: %{dollar_cap: 0.50, token_limit: 0},
      confirmed: true
    }

    assert {:error, :missing_purpose} = Projection.project(spec1)

    # Empty capabilities
    spec2 = %ElicitedSpec{
      purpose: "Surface content",
      capabilities: [],
      spend_limits: %{dollar_cap: 0.50, token_limit: 0},
      confirmed: true
    }

    assert {:error, :empty_capabilities} = Projection.project(spec2)

    # Unknown capability
    spec3 = %ElicitedSpec{
      purpose: "Surface content",
      capabilities: ["unknown_cap_xyz"],
      spend_limits: %{dollar_cap: 0.50, token_limit: 0},
      confirmed: true
    }

    assert {:error, "Connector 'unknown_cap_xyz' is missing from the capability registry."} =
             Projection.project(spec3)
  end

  test "rejects writing manifest to agents/ directory" do
    spec = %ElicitedSpec{
      purpose: "Surface content",
      capabilities: ["kv_append"],
      spend_limits: %{dollar_cap: 0.50, token_limit: 0},
      confirmed: true
    }

    assert {:ok, manifest} = Projection.project(spec)
    assert {:error, :invalid_path} = Projection.write(manifest, "agents/my_agent/manifest.md")
  end
end
