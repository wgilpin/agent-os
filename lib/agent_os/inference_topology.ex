defmodule AgentOS.InferenceTopology do
  @moduledoc """
  Single source of truth for the inference-socket topology mode (feature 045).

  A Unix domain socket is kernel-local. On macOS the BEAM broker historically listened on the
  host kernel while agent containers ran in OrbStack's Linux VM kernel, so a host-bind socket
  file node was shared across the boundary but not its listening endpoint — the agent's
  `connect()` was refused (ECONNREFUSED). The fix runs the substrate as a container in the same
  VM with the socket on a shared named volume mounted at an identical path on both sides.

  The mode is a pure function of one config key, `:inference_socket_volume`:

    * `nil`        -> `:host_bind`   — the socket is a host file bind-mounted at
                      `/tmp/inference.sock` (current behaviour; unchanged when unset).
    * `"<volume>"` -> `:shared_volume` — the socket lives on the named volume mounted at
                      `volume_path/0` in the substrate container and every agent container.

  Every dispatch/sandbox/broker call site derives the mode from `mode/0` — never a second,
  independently-settable switch (contracts/socket-topology.md §1).
  """

  @default_volume_path "/run/aos"

  @typedoc "The two supported socket topologies."
  @type mode() :: :host_bind | :shared_volume

  @doc "Returns the active socket topology mode, derived solely from `:inference_socket_volume`."
  @spec mode() :: mode()
  def mode do
    # Presence of a configured volume name is the sole mode signal.
    if volume_name() == nil, do: :host_bind, else: :shared_volume
  end

  @doc "The named Docker volume carrying the inference socket, or nil in host-bind mode."
  @spec volume_name() :: String.t() | nil
  def volume_name, do: Application.get_env(:agent_os, :inference_socket_volume)

  @doc """
  The directory where the shared volume is mounted inside every container (default `/run/aos`).
  Only meaningful in shared-volume mode; the socket lives under this path.
  """
  @spec volume_path() :: String.t()
  def volume_path,
    do: Application.get_env(:agent_os, :inference_socket_volume_path, @default_volume_path)

  @doc """
  The socket path an agent process sees inside its container (the `INFERENCE_SOCKET` env).

    * host-bind    -> `/tmp/inference.sock` (the fixed container bind target).
    * shared-volume -> the full configured `:inference_uds_path`, which lives under
      `volume_path/0` and is identical on both sides (no translation).
  """
  @spec container_socket_path() :: String.t()
  def container_socket_path do
    case mode() do
      :host_bind ->
        "/tmp/inference.sock"

      :shared_volume ->
        Application.get_env(:agent_os, :inference_uds_path, "#{volume_path()}/inference.sock")
    end
  end
end
