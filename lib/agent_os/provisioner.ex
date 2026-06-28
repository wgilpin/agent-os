defmodule AgentOS.Provisioner do
  @moduledoc """
  Exposes the hard-wired v0 agent config and performs a startup drift check
  against the hand-kept markdown manifest.
  """

  require Logger

  @doc """
  Returns the hard-wired agent config as a map.
  Retrieves parameters from the global Elixir Application configuration environment.
  """
  @spec agent_config() :: map()
  def agent_config do
    # Application.fetch_env!/2 raises an ArgumentError if the key (:agent) is missing
    # in the application scope (:agent_os). It returns a keyword list.
    config = Application.fetch_env!(:agent_os, :agent)

    # Keyword.fetch!/2 fetches the value for a given key, raising an error if missing.
    # We pack the values into a map for structured access.
    %{
      manifest_path: Keyword.fetch!(config, :manifest_path),
      agent_cmd: Keyword.fetch!(config, :agent_cmd),
      agent_args: Keyword.fetch!(config, :agent_args),
      tz: Keyword.fetch!(config, :tz),
      run_hour: Keyword.fetch!(config, :run_hour),
      grants: Keyword.fetch!(config, :grants),
      spend: Keyword.fetch!(config, :spend)
    }
  end

  @doc """
  Compares the hard-wired config grants (grants, spend) against
  the fields declared in manifests/discovery.md. Logs a warning on drift.

  ## Returns
    - `:ok` if config matches manifest.
    - `{:drift, list_of_mismatched_atoms}` if discrepancies are found.
  """
  @spec check_drift() :: :ok | {:drift, [atom()]}
  def check_drift do
    # Fetch the current runtime config map
    config = agent_config()

    # Load and pattern match the manifest
    case AgentOS.Manifest.load(config.manifest_path) do
      {:ok, manifest} ->
        # Initialize an empty list to accumulate mismatches
        mismatched = []

        # 1. Compare grants list.
        manifest_grants =
          Enum.map(manifest.grants, fn g ->
            %{connector: g.connector, recipients: g.recipients, methods: g.methods}
          end)

        mismatched =
          if manifest_grants != config.grants do
            [:grants | mismatched]
          else
            mismatched
          end

        # 2. Compare spend.
        manifest_spend = %{
          cap: manifest.spend.cap,
          window: manifest.spend.window,
          on_breach: manifest.spend.on_breach
        }

        mismatched =
          if manifest_spend != config.spend do
            [:spend | mismatched]
          else
            mismatched
          end

        # Evaluate accumulative results
        if mismatched == [] do
          # Return the atom :ok if lists are fully identical
          :ok
        else
          # Reverse the accumulated list because prepending (consing) builds it backward
          mismatched = Enum.reverse(mismatched)
          # Log a warning message in the system logger
          Logger.warning("manifest drift: mismatched fields #{inspect(mismatched)}")
          {:drift, mismatched}
        end

      {:error, reason} ->
        # Fallback when the manifest file itself couldn't be loaded
        Logger.warning(
          "manifest drift: could not load manifest #{config.manifest_path}: #{inspect(reason)}"
        )

        {:drift, [:manifest]}
    end
  end

  @doc """
  Loads raw bookmarks from a JSON export path, runs them through the Sanitizer,
  and returns the tuple `{sanitized_items, dropped_count}`.
  """
  @spec load_and_sanitize_bookmarks(binary()) :: {[map()], non_neg_integer()}
  def load_and_sanitize_bookmarks(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, items} when is_list(items) ->
              AgentOS.Sanitizer.sanitize_list(items)

            {:ok, other} ->
              Logger.warning("bookmarks JSON at #{path} is not a list: #{inspect(other)}")
              {[], 0}

            {:error, reason} ->
              Logger.warning("bookmarks JSON at #{path} failed to parse: #{inspect(reason)}")
              {[], 0}
          end

        {:error, reason} ->
          Logger.warning("failed to read bookmarks file at #{path}: #{inspect(reason)}")
          {[], 0}
      end
    else
      Logger.warning("bookmarks export file does not exist at #{path}")
      {[], 0}
    end
  end

  @doc """
  Triggers an agent run execution under the RunSupervisor.
  """
  @spec fire_run() :: :ok
  def fire_run do
    # Cast to RunSupervisor to trigger execution asynchronously (cast does not wait).
    AgentOS.RunSupervisor.start_run()
    :ok
  end
end
