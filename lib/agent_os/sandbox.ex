defmodule AgentOS.Sandbox do
  @moduledoc """
  Implements the container sandbox configuration and argv builder (contracts/sandbox.md).
  Ensures that the agent container runs isolated with read-only root FS, limited memory/CPU,
  and dropped privileges (FR-001/008).
  """

  require Logger

  @max_memory_mb 128
  @max_cpus 0.5
  @pids_limit 32
  @nofile_limit "1024:2048"

  # Define the struct holding configuration settings
  defstruct [
    :image,
    :cidfile,
    :network,
    :memory_mb,
    :cpus,
    :user,
    :env,
    :entrypoint,
    :cmd_args,
    :mounts
  ]

  @type t() :: %__MODULE__{
          image: binary(),
          cidfile: binary(),
          network: binary() | nil,
          memory_mb: pos_integer() | nil,
          cpus: binary() | float() | nil,
          user: binary() | nil,
          env: map() | nil,
          entrypoint: binary() | nil,
          cmd_args: [binary()] | nil,
          mounts: [{binary(), binary()}] | nil
        }

  @doc """
  Constructs the docker argument list from the sandbox configuration struct.

  ## Parameters
    - `sandbox`: The `%AgentOS.Sandbox{}` struct containing settings.

  ## Returns
    - A list of binary strings representing arguments for the `docker` command.
  """
  @spec build_argv(t()) :: [binary()]
  def build_argv(%__MODULE__{} = sandbox) do
    # Assign defaults if fields are not specified
    network = sandbox.network || "none"

    if network != "none" do
      raise ArgumentError,
            "Network access is refused in this phase. Allowed network: none. Got: #{inspect(network)}"
    end

    memory_mb = sandbox.memory_mb || @max_memory_mb

    if memory_mb > @max_memory_mb do
      raise ArgumentError,
            "Memory limit #{memory_mb}MB exceeds standard ceiling of #{@max_memory_mb}MB"
    end

    cpus = if sandbox.cpus, do: to_string(sandbox.cpus), else: "0.5"
    parsed_cpus = parse_cpus(cpus)

    if parsed_cpus > @max_cpus do
      raise ArgumentError, "CPU limit #{parsed_cpus} exceeds standard ceiling of #{@max_cpus}"
    end

    user = sandbox.user || "1000:1000"

    # Reject root user configurations (uid 0 / 0:* / root / root:*)
    case String.split(user, ":") |> Enum.map(&String.trim/1) do
      ["0" | _] ->
        raise ArgumentError, "Root user (uid 0) is refused in the sandbox: #{inspect(user)}"

      ["root" | _] ->
        raise ArgumentError, "Root user (root) is refused in the sandbox: #{inspect(user)}"

      _ ->
        :ok
    end

    # Writable-mount validation branches on the socket topology (feature 045). Exactly ONE
    # writable mount is permitted — the inference channel — and every other mount must be
    # read-only (end with ":ro"). The two modes differ only in which mount is the legitimate
    # writable one.
    validate_writable_mounts!(sandbox.mounts || [])

    # Log container start metadata to satisfy Constitution VI (Loud Failures)
    Logger.info(
      "starting sandbox container: image=#{sandbox.image} cpus=#{cpus} memory=#{memory_mb}m network=#{network}"
    )

    # Build entrypoint flags if overridden (useful for testing and generic runs)
    entrypoint_args = if sandbox.entrypoint, do: ["--entrypoint", sandbox.entrypoint], else: []
    cmd_args = sandbox.cmd_args || []

    # Core argument list mapped to the required container configuration
    base_args =
      [
        "run",
        # Remove container automatically when it exits
        "--rm",
        # Interactive mode (attaches stdin to read raw input)
        "-i",
        # Writes container ID to a file for tracking/cleanup
        "--cidfile",
        sandbox.cidfile,
        # Disables or configures network isolation
        "--network",
        network,
        # Read-only root filesystem prevents writing to system directories
        "--read-only",
        # Isolated writable workspace in memory
        "--tmpfs",
        "/scratch:rw,size=64m",
        # Memory allocation limit
        "--memory",
        "#{memory_mb}m",
        # Set swap limit equal to memory to disable swap storage
        "--memory-swap",
        "#{memory_mb}m",
        # Limit CPU core execution usage
        "--cpus",
        cpus,
        # Non-root user inside the container
        "--user",
        user,
        # Limit the number of processes (prevent fork bomb)
        "--pids-limit",
        to_string(@pids_limit),
        # Limit the number of open file descriptors
        "--ulimit",
        "nofile=#{@nofile_limit}",
        # Drop all Linux capabilities
        "--cap-drop",
        "ALL",
        # Prevent container process from gaining new privileges
        "--security-opt",
        "no-new-privileges"
      ] ++ entrypoint_args

    # Convert env map (e.g. %{"KEY" => "VAL"}) to flat lists of arguments `["-e", "KEY=VAL", ...]`
    env_args =
      (sandbox.env || %{})
      |> Enum.flat_map(fn {key, val} -> ["-e", "#{key}=#{val}"] end)

    # Convert mounts list (e.g. [{"/host", "/container"}]) to flat lists of arguments `["-v", "/host:/container", ...]`
    mount_args =
      (sandbox.mounts || [])
      |> Enum.flat_map(fn {host, container} -> ["-v", "#{host}:#{container}"] end)

    # Reconstruct arguments: base docker run arguments + mount args + env vars + image name + command arguments
    base_args ++ mount_args ++ env_args ++ [sandbox.image] ++ cmd_args
  end

  # Enforces the single-writable-mount invariant (FR-005). The legitimate writable mount is the
  # inference channel; its shape depends on the topology mode:
  #   host-bind    -> container target "/tmp/inference.sock"; host source MUST equal the
  #                   configured UDS path (the historical path-equality check).
  #   shared-volume -> container target == the volume mount path; host source MUST equal the
  #                   configured volume name. The legacy /tmp/inference.sock target is NOT
  #                   special in this mode — it would just be another writable mount → rejected.
  # Every non-inference mount must be read-only (":ro"). Violations raise loudly (FR-009).
  defp validate_writable_mounts!(mounts) do
    case AgentOS.InferenceTopology.mode() do
      :host_bind ->
        configured_socket_path =
          Path.expand(Application.get_env(:agent_os, :inference_uds_path, "data/inference.sock"))

        for {host, container} <- mounts do
          if container == "/tmp/inference.sock" do
            if Path.expand(host) != configured_socket_path do
              raise ArgumentError,
                    "Inference socket mount source must match the configured UDS path #{configured_socket_path}. Got: #{host}"
            end
          else
            reject_non_ro!(host, container)
          end
        end

      :shared_volume ->
        volume_name = AgentOS.InferenceTopology.volume_name()
        volume_path = AgentOS.InferenceTopology.volume_path()

        for {host, container} <- mounts do
          if container == volume_path do
            if host != volume_name do
              raise ArgumentError,
                    "The shared inference volume mount at #{volume_path} must have source #{inspect(volume_name)}. Got: #{inspect(host)}"
            end
          else
            reject_non_ro!(host, container)
          end
        end
    end

    :ok
  end

  # Rejects any mount that is not read-only. Shared by both topology branches.
  defp reject_non_ro!(host, container) do
    if not String.ends_with?(container, ":ro") do
      raise ArgumentError,
            "Only the legitimate inference-UDS mount is allowed to be writable. All other mounts must be read-only (end with :ro). Got mount: {#{inspect(host)}, #{inspect(container)}}"
    end
  end

  # Helper to parse cpus parameter to float
  defp parse_cpus(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} ->
        f

      :error ->
        case Integer.parse(val) do
          {i, _} -> i * 1.0
          :error -> raise ArgumentError, "Invalid CPU allocation format: #{inspect(val)}"
        end
    end
  end

  defp parse_cpus(val) when is_number(val), do: val * 1.0
end
