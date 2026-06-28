defmodule AgentOS.Sandbox do
  @moduledoc """
  Implements the container sandbox configuration and argv builder (contracts/sandbox.md).
  Ensures that the agent container runs isolated with read-only root FS, limited memory/CPU,
  and dropped privileges (FR-001/008).
  """

  require Logger

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
    :cmd_args
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
          cmd_args: [binary()] | nil
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
    memory_mb = sandbox.memory_mb || 128
    cpus = if sandbox.cpus, do: to_string(sandbox.cpus), else: "0.5"
    user = sandbox.user || "1000:1000"

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

    # Reconstruct arguments: base docker run arguments + env vars + image name + command arguments
    base_args ++ env_args ++ [sandbox.image] ++ cmd_args
  end
end
