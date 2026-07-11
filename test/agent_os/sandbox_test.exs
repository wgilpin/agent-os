defmodule AgentOS.SandboxTest do
  use ExUnit.Case, async: false

  alias AgentOS.Sandbox

  # Default every test to host-bind mode so the host-bind mount-validation assertions are correct
  # even when the suite runs in-container (feature 045 sets shared-volume globally there). The
  # shared-volume describe block overrides this in its own setup.
  setup do
    prev_vol = Application.get_env(:agent_os, :inference_socket_volume)
    Application.delete_env(:agent_os, :inference_socket_volume)

    on_exit(fn ->
      if prev_vol,
        do: Application.put_env(:agent_os, :inference_socket_volume, prev_vol),
        else: Application.delete_env(:agent_os, :inference_socket_volume)
    end)

    :ok
  end

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

  test "build_argv/1 rejects root user configurations" do
    base = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: "/tmp/cidfile.txt",
      network: "none",
      memory_mb: 128,
      cpus: "0.5"
    }

    root_users = ["0", "0:0", "0:1000", "root", "root:root", "  0 : 1000 "]

    for user <- root_users do
      sandbox = %{base | user: user}

      assert_raise ArgumentError, ~r/refused/i, fn ->
        Sandbox.build_argv(sandbox)
      end
    end
  end

  test "build_argv/1 unconditionally includes cap-drop and security-opt flags" do
    sandbox = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: "/tmp/cidfile.txt",
      user: "1000:1000"
    }

    argv = Sandbox.build_argv(sandbox)
    assert "--cap-drop" in argv
    assert "ALL" in argv
    assert "--security-opt" in argv
    assert "no-new-privileges" in argv
  end

  test "build_argv/1 enforces resource ceilings and limits" do
    base = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: "/tmp/cidfile.txt",
      user: "1000:1000"
    }

    assert_raise ArgumentError, ~r/memory limit.*exceeds/i, fn ->
      Sandbox.build_argv(%{base | memory_mb: 129})
    end

    assert_raise ArgumentError, ~r/cpu limit.*exceeds/i, fn ->
      Sandbox.build_argv(%{base | cpus: 0.6})
    end

    assert_raise ArgumentError, ~r/cpu limit.*exceeds/i, fn ->
      Sandbox.build_argv(%{base | cpus: "0.6"})
    end

    argv = Sandbox.build_argv(%{base | memory_mb: 128, cpus: 0.5})
    assert get_val(argv, "--memory") == "128m"
    assert get_val(argv, "--cpus") == "0.5"

    argv_lower = Sandbox.build_argv(%{base | memory_mb: 64, cpus: 0.2})
    assert get_val(argv_lower, "--memory") == "64m"
    assert get_val(argv_lower, "--cpus") == "0.2"

    assert "--pids-limit" in argv
    assert get_val(argv, "--pids-limit") == "32"
    assert "--ulimit" in argv
    assert get_val(argv, "--ulimit") == "nofile=1024:2048"
  end

  test "build_argv/1 restricts network mode to none" do
    base = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: "/tmp/cidfile.txt",
      user: "1000:1000"
    }

    assert_raise ArgumentError, ~r/network access is refused/i, fn ->
      Sandbox.build_argv(%{base | network: "host"})
    end

    assert_raise ArgumentError, ~r/network access is refused/i, fn ->
      Sandbox.build_argv(%{base | network: "bridge"})
    end

    argv = Sandbox.build_argv(base)
    assert get_val(argv, "--network") == "none"
  end

  test "build_argv/1 restricts mounts to read-only except inference socket" do
    base = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: "/tmp/cidfile.txt",
      user: "1000:1000"
    }

    original_uds_path = Application.get_env(:agent_os, :inference_uds_path)
    Application.put_env(:agent_os, :inference_uds_path, "/host/path")

    on_exit(fn ->
      if original_uds_path,
        do: Application.put_env(:agent_os, :inference_uds_path, original_uds_path),
        else: Application.delete_env(:agent_os, :inference_uds_path)
    end)

    argv = Sandbox.build_argv(%{base | mounts: [{"/host/path", "/tmp/inference.sock"}]})
    assert "-v" in argv
    assert "/host/path:/tmp/inference.sock" in argv

    assert_raise ArgumentError, ~r/only.*inference-UDS.*allowed to be writable/i, fn ->
      Sandbox.build_argv(%{base | mounts: [{"/host/path", "/tmp/other.sock"}]})
    end

    argv_ro = Sandbox.build_argv(%{base | mounts: [{"/host/path", "/tmp/other.sock:ro"}]})
    assert "-v" in argv_ro
    assert "/host/path:/tmp/other.sock:ro" in argv_ro
  end

  test "US2: build_argv/1 generates correct user argument when group is custom GID" do
    sandbox = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: "/tmp/cidfile.txt",
      user: "1000:1050"
    }

    argv = Sandbox.build_argv(sandbox)
    assert get_val(argv, "--user") == "1000:1050"
  end

  test "US4: build_argv/1 blocks writable mounts that are not configured inference socket" do
    base = %Sandbox{
      image: "agent-discovery:dev",
      cidfile: "/tmp/cidfile.txt",
      user: "1000:1000"
    }

    # Custom writable mount to other path is blocked
    assert_raise ArgumentError, ~r/only.*inference-UDS.*allowed to be writable/i, fn ->
      Sandbox.build_argv(%{base | mounts: [{"/host/path", "/tmp/other.sock"}]})
    end

    # Mount to /tmp/inference.sock but with wrong host path is blocked
    assert_raise ArgumentError, ~r/Inference socket mount source must match/i, fn ->
      Sandbox.build_argv(%{base | mounts: [{"/wrong/host/path", "/tmp/inference.sock"}]})
    end
  end

  describe "shared-volume mode writable-mount validation (feature 045, FR-005)" do
    setup do
      prev_vol = Application.get_env(:agent_os, :inference_socket_volume)
      prev_path = Application.get_env(:agent_os, :inference_socket_volume_path)
      Application.put_env(:agent_os, :inference_socket_volume, "aos_inf")
      Application.put_env(:agent_os, :inference_socket_volume_path, "/run/aos")

      on_exit(fn ->
        if prev_vol,
          do: Application.put_env(:agent_os, :inference_socket_volume, prev_vol),
          else: Application.delete_env(:agent_os, :inference_socket_volume)

        if prev_path,
          do: Application.put_env(:agent_os, :inference_socket_volume_path, prev_path),
          else: Application.delete_env(:agent_os, :inference_socket_volume_path)
      end)

      base = %Sandbox{
        image: "agent-generated:dev",
        cidfile: "/tmp/cidfile.txt",
        user: "1000:1000"
      }

      {:ok, base: base}
    end

    test "accepts the named volume as the sole writable mount", %{base: base} do
      argv = Sandbox.build_argv(%{base | mounts: [{"aos_inf", "/run/aos"}]})
      assert "aos_inf:/run/aos" in argv
    end

    test "accepts the volume mount alongside :ro code mounts", %{base: base} do
      argv =
        Sandbox.build_argv(%{
          base
          | mounts: [{"aos_inf", "/run/aos"}, {"/host/agents/x", "/app/agents/x:ro"}]
        })

      assert "aos_inf:/run/aos" in argv
      assert "/host/agents/x:/app/agents/x:ro" in argv
    end

    test "rejects a writable mount at the volume path with the wrong source", %{base: base} do
      assert_raise ArgumentError, ~r/shared inference volume/i, fn ->
        Sandbox.build_argv(%{base | mounts: [{"wrong_vol", "/run/aos"}]})
      end
    end

    test "rejects any other writable (non-:ro) mount", %{base: base} do
      assert_raise ArgumentError, ~r/read-only|:ro/i, fn ->
        Sandbox.build_argv(%{base | mounts: [{"aos_inf", "/run/aos"}, {"/x", "/tmp/other"}]})
      end
    end

    test "the legacy /tmp/inference.sock host-bind path is NOT special in volume mode",
         %{base: base} do
      # In volume mode a /tmp/inference.sock mount is just another writable mount → rejected.
      assert_raise ArgumentError, ~r/read-only|:ro/i, fn ->
        Sandbox.build_argv(%{base | mounts: [{"/host/path", "/tmp/inference.sock"}]})
      end
    end
  end

  # Helper to fetch the value following a flag in the argv list
  defp get_val(argv, flag) do
    case Enum.find_index(argv, &(&1 == flag)) do
      nil -> nil
      idx -> Enum.at(argv, idx + 1)
    end
  end
end
