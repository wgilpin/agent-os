defmodule AgentOS.BoundaryTest do
  use ExUnit.Case, async: false

  alias AgentOS.Manifest
  alias AgentOS.Sandbox
  alias AgentOS.RunWorker
  alias AgentOS.CredentialProxy

  setup do
    start_supervised!(CredentialProxy)
    :ok
  end

  test "boundary invariants: manifest never crosses to the agent" do
    # 1. Anti-vacuousness check: load real manifest and assert grants and spend are populated (VR-006)
    manifest_path = "manifests/discovery.md"
    assert {:ok, %Manifest{} = manifest} = Manifest.load(manifest_path)
    assert length(manifest.grants) > 0
    refute is_nil(manifest.spend)

    # 2. Build agent-bound payload via RunWorker.build_payload/2 and assert invariants
    sample_snapshot = %{records: [%{"name" => "Alice", "role" => "Admin"}]}
    sample_items = [%{"id" => 1, "title" => "Important News"}]

    payload = RunWorker.build_payload(sample_snapshot, sample_items)
    json = Jason.encode!(payload)

    # VR-001: top-level keys must be exactly ["items", "state"]
    assert Map.keys(payload) == ["items", "state"]

    # VR-002: none of the envelope keys must appear in the serialized payload
    envelope_keys = [
      "grants",
      "recipients",
      "methods",
      "cost",
      "requires_deploy_consent",
      "requires_runtime_approval",
      "spend",
      "cap",
      "window",
      "on_breach"
    ]

    for key <- envelope_keys do
      refute String.contains?(json, key), "Payload JSON leaked envelope key: #{key}"
    end

    # VR-003: none of the configured envelope values or credential ID must appear
    configured_values =
      Enum.flat_map(manifest.grants, fn g ->
        [g.connector] ++ (g.recipients || []) ++ (g.methods || [])
      end) ++
        [
          to_string(manifest.spend.cap),
          to_string(manifest.spend.window),
          to_string(manifest.spend.on_breach),
          "outbound_token"
        ]

    for val <- configured_values do
      refute String.contains?(json, val), "Payload JSON leaked configured envelope value: #{val}"
    end

    # 3. Sandbox argv asserts
    sandbox = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: "test_cidfile.txt",
      env: %{"SOME_OTHER" => "value"}
    }

    argv = Sandbox.build_argv(sandbox)

    # VR-004: Sandbox argv contains no bind mount flag and no element referencing manifest/discovery.md
    refute Enum.member?(argv, "-v")
    refute Enum.member?(argv, "--volume")

    for arg <- argv do
      refute String.contains?(arg, "manifest"), "Sandbox argv leaked manifest path: #{arg}"
      refute String.contains?(arg, "discovery.md"), "Sandbox argv leaked manifest path: #{arg}"
    end

    # VR-005: Sandbox argv contains no mutating credential id
    for arg <- argv do
      refute String.contains?(arg, "outbound_token"),
             "Sandbox argv leaked mutating credential ID: #{arg}"
    end

    # C1: Assert that mutating and inference-only credential values are absent from the real agent-bound payload and the container env (argv)
    refute String.contains?(json, "test_secret_outbound_token_value"),
           "Payload leaked outbound token value"

    refute String.contains?(json, "test_secret_model_key_value"), "Payload leaked model key value"

    for arg <- argv do
      refute String.contains?(arg, "test_secret_outbound_token_value"),
             "Sandbox argv leaked outbound token value: #{arg}"

      refute String.contains?(arg, "test_secret_model_key_value"),
             "Sandbox argv leaked model key value: #{arg}"
    end
  end
end
