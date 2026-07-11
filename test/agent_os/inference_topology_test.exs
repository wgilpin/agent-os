defmodule AgentOS.InferenceTopologyTest do
  # Unit tests for the single source of truth that derives the inference socket topology mode
  # from `:inference_socket_volume`. Every dispatch/sandbox/broker call site reads mode/0 from
  # here, so this locks the mode-selection contract (contracts/socket-topology.md §1).
  use ExUnit.Case, async: false

  alias AgentOS.InferenceTopology

  setup do
    prev_vol = Application.get_env(:agent_os, :inference_socket_volume)
    prev_path = Application.get_env(:agent_os, :inference_socket_volume_path)

    on_exit(fn ->
      if prev_vol,
        do: Application.put_env(:agent_os, :inference_socket_volume, prev_vol),
        else: Application.delete_env(:agent_os, :inference_socket_volume)

      if prev_path,
        do: Application.put_env(:agent_os, :inference_socket_volume_path, prev_path),
        else: Application.delete_env(:agent_os, :inference_socket_volume_path)
    end)

    :ok
  end

  test "mode/0 is :host_bind when no volume is configured" do
    Application.delete_env(:agent_os, :inference_socket_volume)
    assert InferenceTopology.mode() == :host_bind
  end

  test "mode/0 is :shared_volume when a volume is configured" do
    Application.put_env(:agent_os, :inference_socket_volume, "aos_inf")
    assert InferenceTopology.mode() == :shared_volume
  end

  test "volume_name/0 and volume_path/0 return the configured values in shared mode" do
    Application.put_env(:agent_os, :inference_socket_volume, "aos_inf")
    Application.put_env(:agent_os, :inference_socket_volume_path, "/run/aos")
    assert InferenceTopology.volume_name() == "aos_inf"
    assert InferenceTopology.volume_path() == "/run/aos"
  end

  test "volume_path/0 defaults to /run/aos when unset" do
    Application.delete_env(:agent_os, :inference_socket_volume_path)
    assert InferenceTopology.volume_path() == "/run/aos"
  end

  test "container_socket_path/0 is /tmp/inference.sock in host-bind mode" do
    Application.delete_env(:agent_os, :inference_socket_volume)
    assert InferenceTopology.container_socket_path() == "/tmp/inference.sock"
  end

  test "container_socket_path/0 is the in-volume uds path in shared-volume mode" do
    prev_uds = Application.get_env(:agent_os, :inference_uds_path)

    on_exit(fn ->
      if prev_uds,
        do: Application.put_env(:agent_os, :inference_uds_path, prev_uds),
        else: Application.delete_env(:agent_os, :inference_uds_path)
    end)

    Application.put_env(:agent_os, :inference_socket_volume, "aos_inf")
    Application.put_env(:agent_os, :inference_socket_volume_path, "/run/aos")
    Application.put_env(:agent_os, :inference_uds_path, "/run/aos/inference.sock")
    assert InferenceTopology.container_socket_path() == "/run/aos/inference.sock"
  end
end
