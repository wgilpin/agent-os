defmodule AgentOS.CapabilityRenderTest do
  use ExUnit.Case, async: false

  alias AgentOS.CapabilityRender
  alias AgentOS.CapabilityRender.Entry
  alias AgentOS.Manifest
  alias AgentOS.Manifest.Grant
  alias AgentOS.Manifest.Spend

  # Traceability check (contract tests C1–C12):
  # C1 -> test "C1: totality - one entry per grant in discovery_manifest"
  # C2 -> test "C2: totality - send never dropped"
  # C3 -> test "C3: danger-ranked field comparison"
  # C3f -> test "C3f: danger-ranked formatting comparison"
  # C4 -> test "C4: danger derived from registry only"
  # C5 -> test "C5: faithful - add"
  # C6 -> test "C6: faithful - remove"
  # C7 -> test "C7: faithful - rescope"
  # C8 -> test "C8: never-LLM / deterministic byte-identical formatting"
  # C9 -> test "C9: fallback phrase for unmapped connector"
  # C10 -> test "C10: loud failure for connector missing from registry"
  # C11 -> test "C11: agent-agnostic rendering"
  # C12 -> (implemented in test/agent_os/inventory_test.exs)

  setup do
    # Save current registry state to restore after each test
    original_registry = Application.get_env(:agent_os, :connector_registry)

    on_exit(fn ->
      if original_registry == nil do
        Application.delete_env(:agent_os, :connector_registry)
      else
        Application.put_env(:agent_os, :connector_registry, original_registry)
      end
    end)

    :ok
  end

  defp mock_manifest(grants) do
    %Manifest{
      purpose: "test",
      triggers: [],
      grants: grants,
      mounts: [],
      spend: %Spend{cap: 5000, window: :daily, on_breach: :kill},
      owner: "human",
      supervision: "restart"
    }
  end

  test "C1: totality - one entry per grant in discovery_manifest" do
    {:ok, manifest} = Manifest.load("test/fixtures/manifests/discovery.md")
    entries = CapabilityRender.entries(manifest)
    assert length(entries) == length(manifest.grants)

    connectors = Enum.map(entries, & &1.connector)
    assert "kv_append" in connectors
    assert "external_send" in connectors
  end

  test "C2: totality - send never dropped" do
    manifest = mock_manifest([%Grant{connector: "external_send"}])
    entries = CapabilityRender.entries(manifest)
    assert [%Entry{connector: "external_send"}] = entries
  end

  test "C3: danger-ranked field comparison" do
    manifest =
      mock_manifest([
        %Grant{connector: "kv_append"},
        %Grant{connector: "external_send"}
      ])

    [kv_entry, ext_entry] = CapabilityRender.entries(manifest)
    assert kv_entry.danger == :local
    assert ext_entry.danger == :external

    # Assert external > local > read_only
    # (Using a helper comparison or direct check since atoms don't naturally compare this way in Elixir)
    assert danger_rank(ext_entry.danger) > danger_rank(kv_entry.danger)
  end

  test "C3f: danger-ranked formatting comparison" do
    manifest =
      mock_manifest([
        %Grant{connector: "kv_append"},
        %Grant{connector: "external_send"}
      ])

    formatted = CapabilityRender.render(manifest)
    lines = String.split(formatted, "\n", trim: true)

    # Find the lines containing kv_append and external_send
    kv_line = Enum.find(lines, &String.contains?(&1, "WRITE TO YOUR LOCAL"))
    ext_line = Enum.find(lines, &String.contains?(&1, "SEND MESSAGES OUT"))

    assert kv_line != nil
    assert ext_line != nil

    # The external_send line must have a distinct danger marker/tag that the kv_append line does not have,
    # or the external_send line's marker represents a higher level of danger.
    # We assert that the external line is format-distinguished.
    # To test the presence/absence of marker, we can check for a warning/critical tag.
    assert ext_line =~ "[EXTERNAL]" or ext_line =~ "⚠️" or ext_line =~ "!"
  end

  test "C4: danger derived from registry only" do
    # If we override the registry to make external_send free, credential-less, no-approval,
    # its tier should become :local (or :read_only if not mutating).
    custom_registry = %{
      "external_send" => %{
        name: "external_send",
        mutating?: true,
        requires_deploy_consent?: false,
        requires_runtime_approval?: false,
        credential: nil,
        cost: 0
      }
    }

    Application.put_env(:agent_os, :connector_registry, custom_registry)

    manifest = mock_manifest([%Grant{connector: "external_send"}])
    [entry] = CapabilityRender.entries(manifest)
    assert entry.danger == :local

    # If it is not mutating, it should be :read_only
    read_only_registry = %{
      "external_send" => %{
        name: "external_send",
        mutating?: false,
        requires_deploy_consent?: false,
        requires_runtime_approval?: false,
        credential: nil,
        cost: 0
      }
    }

    Application.put_env(:agent_os, :connector_registry, read_only_registry)
    [entry_ro] = CapabilityRender.entries(manifest)
    assert entry_ro.danger == :read_only

    # Changing recipients or methods (scope) on the grant does NOT change its tier.
    # revert to default
    Application.delete_env(:agent_os, :connector_registry)

    scoped_manifest =
      mock_manifest([
        %Grant{connector: "external_send", recipients: ["user"], methods: ["send"]}
      ])

    [scoped_entry] = CapabilityRender.entries(scoped_manifest)
    assert scoped_entry.danger == :external
  end

  test "C5: faithful - add" do
    manifest = mock_manifest([%Grant{connector: "kv_append"}])
    assert length(CapabilityRender.entries(manifest)) == 1

    added =
      mock_manifest([
        %Grant{connector: "kv_append"},
        %Grant{connector: "external_send"}
      ])

    assert length(CapabilityRender.entries(added)) == 2
  end

  test "C6: faithful - remove" do
    manifest =
      mock_manifest([
        %Grant{connector: "kv_append"},
        %Grant{connector: "external_send"}
      ])

    assert length(CapabilityRender.entries(manifest)) == 2

    removed = mock_manifest([%Grant{connector: "external_send"}])
    assert length(CapabilityRender.entries(removed)) == 1
  end

  test "C7: faithful - rescope" do
    manifest =
      mock_manifest([
        %Grant{connector: "external_send", recipients: ["old-inbox"], methods: ["send"]}
      ])

    formatted_old = CapabilityRender.render(manifest)
    assert formatted_old =~ "old-inbox"

    rescoped =
      mock_manifest([
        %Grant{connector: "external_send", recipients: ["new-inbox"], methods: ["post"]}
      ])

    formatted_new = CapabilityRender.render(rescoped)
    assert formatted_new =~ "new-inbox"
    refute formatted_new =~ "old-inbox"
  end

  test "C8: never-LLM / deterministic byte-identical formatting" do
    manifest =
      mock_manifest([
        %Grant{connector: "kv_append"},
        %Grant{connector: "external_send"}
      ])

    f1 = CapabilityRender.render(manifest)
    f2 = CapabilityRender.render(manifest)
    assert f1 == f2
  end

  test "C9: fallback phrase for unmapped connector" do
    # Override registry to add an unmapped connector "some_new_connector"
    custom_registry = %{
      "some_new_connector" => %{
        name: "some_new_connector",
        mutating?: true,
        requires_deploy_consent?: false,
        requires_runtime_approval?: false,
        credential: nil,
        cost: 0
      }
    }

    Application.put_env(:agent_os, :connector_registry, custom_registry)

    manifest = mock_manifest([%Grant{connector: "some_new_connector"}])
    [entry] = CapabilityRender.entries(manifest)

    assert entry.phrase_source == :fallback
    assert entry.phrase =~ "some_new_connector"
    assert entry.danger == :local
  end

  test "C10: loud failure for connector missing from registry" do
    # The registry has no entry for "missing_connector"
    manifest = mock_manifest([%Grant{connector: "missing_connector"}])

    assert_raise RuntimeError, ~r/registry/i, fn ->
      CapabilityRender.entries(manifest)
    end
  end

  test "C11: agent-agnostic rendering" do
    manifest1 = mock_manifest([%Grant{connector: "kv_append"}])

    manifest2 = %Manifest{
      purpose: "different",
      triggers: [],
      grants: [%Grant{connector: "kv_append"}],
      mounts: [],
      spend: %Spend{cap: 1000, window: :daily, on_breach: :kill},
      owner: "assistant",
      supervision: "terminate"
    }

    [entry1] = CapabilityRender.entries(manifest1)
    [entry2] = CapabilityRender.entries(manifest2)

    assert entry1.phrase == entry2.phrase
    assert entry1.danger == entry2.danger
  end

  defp danger_rank(:read_only), do: 1
  defp danger_rank(:local), do: 2
  defp danger_rank(:external), do: 3
end
