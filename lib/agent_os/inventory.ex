defmodule AgentOS.Inventory do
  @moduledoc """
  Implements the standing inventory render (REQ-list-inventory).
  Extracts the manifest definition and the current runtime state from
  the RosterStore without communicating with the agent process.
  """

  @doc """
  Renders a human-readable standing inventory report.

  ## Parameters
    - `opts`: Keyword list that can override the `:manifest_path`.

  ## Returns
    - A multi-line string containing the rendered report.
  """
  @spec render(keyword()) :: binary()
  def render(opts \\ []) do
    # Safely attempt to read the agent config.
    # We use a try-rescue block to fall back to a default manifest path if the
    # application config is not fully initialized (e.g. during certain test configurations).
    agent_config =
      try do
        AgentOS.Provisioner.agent_config()
      rescue
        _ -> %{manifest_path: "manifests/discovery.md"}
      end

    # Retrieve the manifest path. Keyword.get/3 extracts the value of :manifest_path from opts,
    # and if not present, defaults to the one defined in the config.
    manifest_path = Keyword.get(opts, :manifest_path, agent_config.manifest_path)

    # load the YAML frontmatter manifest from the file system.
    # Elixir uses `case` for pattern matching on tagged tuples like `{:ok, val}` or `{:error, reason}`.
    case AgentOS.Manifest.load(manifest_path) do
      {:ok, manifest} ->
        # Fetch the current state snapshot from the StateStore GenServer named :roster_trust.
        snapshot = AgentOS.StateStore.snapshot("roster_trust")
        
        # Calculate the total number of records recorded in state.
        records_count = length(snapshot.records)

        # Search for the last digest entry.
        # |> is the pipe operator: it passes the result of the previous expression as
        # the first argument of the next function.
        last_digest =
          snapshot.records
          |> Enum.reverse() # Start searching from the most recent records first
          |> Enum.find_value("none", fn # If no value matches, return the string "none"
            # Pattern match on map to extract value of "digest" key.
            %{"digest" => text} -> text
            # Ignore other shapes of records.
            _ -> nil
          end)

        # Build and return the final report string using multiline heredoc (`"""`).
        # `#{expression}` is used for string interpolation.
        """
        Agent OS Standing Inventory
        ===========================
        PURPOSE: #{manifest["purpose"]}
        TRIGGERS: #{inspect(manifest["triggers"])}
        CONNECTORS: #{inspect(manifest["connectors"])}
        MOUNTS: #{inspect(manifest["mounts"])}
        OUTPUTS: #{inspect(manifest["outputs"])}
        SPEND CAP: #{get_in(manifest, ["spend", "cap"])}
        OWNER/SUPERVISION: #{manifest["owner"]} / #{manifest["supervision"]}

        LAST RUN STATE:
        Total Records: #{records_count}
        Last Digest: #{last_digest}
        """

      {:error, reason} ->
        # Return a formatted error message string if manifest loading failed.
        "ERROR: Could not load manifest at #{manifest_path}: #{inspect(reason)}"
    end
  end
end
