defmodule AgentOS.DispatchTopologyTest do
  # Locks the dispatch-side socket topology contract (contracts/socket-topology.md §2):
  # the inference mount source in shared-volume mode is the NAMED VOLUME, not a host path,
  # while the generated-agent code mount stays byte-for-byte identical (FR-010 / 044 FR-007).
  use ExUnit.Case, async: false

  alias AgentOS.RunWorker

  @config_agent "discovery"

  setup do
    keys = [
      :inference_socket_volume,
      :inference_socket_volume_path,
      :inference_uds_path
    ]

    prev = Enum.map(keys, fn k -> {k, Application.get_env(:agent_os, k)} end)

    on_exit(fn ->
      Enum.each(prev, fn {k, v} ->
        if v == nil,
          do: Application.delete_env(:agent_os, k),
          else: Application.put_env(:agent_os, k, v)
      end)
    end)

    :ok
  end

  describe "host-bind mode (no volume configured)" do
    setup do
      Application.delete_env(:agent_os, :inference_socket_volume)
      Application.put_env(:agent_os, :inference_uds_path, "data/inference.sock")
      :ok
    end

    test "config agent inference mount is the host socket path at /tmp/inference.sock" do
      spec = RunWorker.dispatch_spec(@config_agent, @config_agent)
      expected_host = Path.expand("data/inference.sock")
      assert {expected_host, "/tmp/inference.sock"} in spec.mounts
    end

    test "generated agent keeps host socket mount plus the :ro code mount" do
      spec = RunWorker.dispatch_spec("gen_x", @config_agent)
      expected_host = Path.expand("data/inference.sock")
      assert {expected_host, "/tmp/inference.sock"} in spec.mounts
      code_dir = Path.expand(Path.join(["agents", "gen_x"]))
      assert {code_dir, "/app/agents/gen_x:ro"} in spec.mounts
    end
  end

  describe "shared-volume mode" do
    setup do
      Application.put_env(:agent_os, :inference_socket_volume, "aos_inf")
      Application.put_env(:agent_os, :inference_socket_volume_path, "/run/aos")
      Application.put_env(:agent_os, :inference_uds_path, "/run/aos/inference.sock")
      :ok
    end

    test "config agent inference mount is the named volume, not a host path" do
      spec = RunWorker.dispatch_spec(@config_agent, @config_agent)
      assert {"aos_inf", "/run/aos"} in spec.mounts
      # No host-path socket mount leaks through in volume mode.
      refute Enum.any?(spec.mounts, fn {_h, c} -> c == "/tmp/inference.sock" end)
    end

    test "generated agent uses the volume mount AND the identical :ro code mount (FR-010 parity)" do
      spec = RunWorker.dispatch_spec("gen_x", @config_agent)
      assert {"aos_inf", "/run/aos"} in spec.mounts
      code_dir = Path.expand(Path.join(["agents", "gen_x"]))
      assert {code_dir, "/app/agents/gen_x:ro"} in spec.mounts
    end
  end
end
