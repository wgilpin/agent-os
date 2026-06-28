defmodule AgentOS.SandboxTest do
  use ExUnit.Case, async: true

  alias AgentOS.Sandbox

  test "build_argv/1 generates correct docker run argument list" do
    sandbox = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: "/tmp/cidfile.txt",
      network: "none",
      memory_mb: 128,
      cpus: "0.5",
      user: "1000:1000",
      env: %{"HTTPS_PROXY" => "http://proxy.orb.internal:8305"}
    }

    argv = Sandbox.build_argv(sandbox)

    assert "run" in argv
    assert "--rm" in argv
    assert "-i" in argv
    assert "--read-only" in argv
    assert "--cap-drop" in argv
    assert "ALL" in argv
    assert "--security-opt" in argv
    assert "no-new-privileges" in argv

    # Check key-value pairings in arguments
    assert get_val(argv, "--cidfile") == "/tmp/cidfile.txt"
    assert get_val(argv, "--network") == "none"
    assert get_val(argv, "--tmpfs") == "/scratch:rw,size=64m"
    assert get_val(argv, "--memory") == "128m"
    assert get_val(argv, "--memory-swap") == "128m"
    assert get_val(argv, "--cpus") == "0.5"
    assert get_val(argv, "--user") == "1000:1000"

    # Environment variables
    assert "-e" in argv
    assert "HTTPS_PROXY=http://proxy.orb.internal:8305" in argv

    # The image name should be the final argument
    assert List.last(argv) == "agent-discovery:dev"
  end

  # Helper to fetch the value following a flag in the argv list
  defp get_val(argv, flag) do
    case Enum.find_index(argv, &(&1 == flag)) do
      nil -> nil
      idx -> Enum.at(argv, idx + 1)
    end
  end
end
