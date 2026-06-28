defmodule AgentOS.ManifestTest do
  use ExUnit.Case, async: true

  alias AgentOS.Manifest

  @manifest "manifests/discovery.md"

  test "load returns {:ok, map} with all seven core fields" do
    assert {:ok, map} = Manifest.load(@manifest)

    for key <- ~w(purpose triggers connectors mounts outputs spend) do
      assert Map.has_key?(map, key), "missing manifest field: #{key}"
    end

    assert Map.has_key?(map, "owner") or Map.has_key?(map, "supervision")
  end

  test "purpose is a non-empty string (one-line contract)" do
    assert {:ok, %{"purpose" => purpose}} = Manifest.load(@manifest)
    assert is_binary(purpose) and String.trim(purpose) != ""
  end

  test "spend.cap is an integer" do
    assert {:ok, %{"spend" => %{"cap" => cap}}} = Manifest.load(@manifest)
    assert is_integer(cap)
  end

  test "connectors and mounts are lists" do
    assert {:ok, %{"connectors" => connectors, "mounts" => mounts}} = Manifest.load(@manifest)
    assert is_list(connectors)
    assert is_list(mounts)
  end

  test "missing file returns {:error, _} without crashing" do
    assert {:error, _} = Manifest.load("manifests/does_not_exist.md")
  end
end
