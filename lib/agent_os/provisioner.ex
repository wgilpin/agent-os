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

  @doc """
  Runs the deploy-time safety rail checking if the deployment must block on a human.
  """
  @spec deploy(binary(), atom() | String.t(), keyword()) ::
          {:ok, atom()}
          | {:blocked, binary()}
          | {:error, any()}
  def deploy(manifest_path, review_mode, opts \\ []) do
    agent_name = Path.basename(manifest_path, ".md")

    case AgentOS.Manifest.load(manifest_path) do
      {:ok, manifest} ->
        # Render and log capabilities (Constitution VIII, REQ-always-emit)
        cap_render = AgentOS.CapabilityRender.render(manifest)
        Logger.info("Deploying Agent '#{agent_name}' with capabilities:\n#{cap_render}")

        hash = manifest_hash(manifest_path)
        normalized_mode = normalize_mode(review_mode)

        # Check if already deployed with matching manifest hash
        case get_recorded_provenance(agent_name) do
          %{status: status, hash: ^hash} ->
            {:ok, status}

          _ ->
            in_envelope? = envelope_predicate?(manifest, opts)
            conformance_flagged? = gate_breach_flagged?(agent_name, opts)
            is_risky? = not in_envelope? or conformance_flagged?

            should_block? =
              case normalized_mode do
                :always_review -> true
                :review_if_risky -> is_risky?
                :dangerously_skip_review -> false
              end

            if should_block? do
              ref = "ref_deploy_#{agent_name}_#{System.unique_integer([:positive])}"

              action = %AgentOS.ProposedAction{
                type: "deploy",
                recipient: agent_name,
                method: manifest_path,
                payload: %{"review_mode" => to_string(normalized_mode), "hash" => hash}
              }

              grant = %AgentOS.Manifest.Grant{
                connector: "deploy",
                recipients: nil,
                methods: nil
              }

              pending_store = AgentOS.StateStore.snapshot("pending_approvals")
              approvals = Map.get(pending_store, :approvals, %{})

              updated_approvals =
                Map.put(approvals, ref, %{ref: ref, action: action, grant: grant})

              :ok =
                AgentOS.StateStore.apply_action(
                  "pending_approvals",
                  {:put, :approvals, updated_approvals}
                )

              {:blocked, ref}
            else
              provenance =
                case normalized_mode do
                  :review_if_risky -> :skipped_in_envelope
                  :dangerously_skip_review -> :dangerously_skipped
                end

              :ok = record_provenance(agent_name, provenance, hash)
              {:ok, provenance}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Pure deterministic boolean evaluator over manifest fields.
  """
  @spec envelope_predicate?(AgentOS.Manifest.t(), keyword()) :: boolean()
  def envelope_predicate?(manifest, opts \\ []) do
    # 1. Read-only: grants mutate no state
    entries = AgentOS.CapabilityRender.entries(manifest)
    read_only? = Enum.all?(entries, fn entry -> entry.danger == :read_only end)

    # 2. No-egress: danger level not external
    no_egress? = Enum.all?(entries, fn entry -> entry.danger != :external end)

    # 3. Spend cap under threshold (default 100_000 micro-dollars / $0.10)
    threshold = Keyword.get(opts, :spend_threshold, 100_000)
    spend_under_threshold? = manifest.spend.cap <= threshold

    read_only? and no_egress? and spend_under_threshold?
  end

  @doc """
  Computes SHA-256 hash of the manifest file.
  """
  @spec manifest_hash(binary()) :: binary()
  def manifest_hash(manifest_path) do
    case File.read(manifest_path) do
      {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16()
      _ -> ""
    end
  end

  @doc """
  Writes provenance metadata for the agent to the provenance StateStore.
  """
  @spec record_provenance(binary(), atom(), binary()) :: :ok
  def record_provenance(agent_name, status, hash) do
    provenance_record = %{status: status, hash: hash}
    AgentOS.StateStore.apply_action("provenance", {:put, agent_name, provenance_record})
  end

  defp get_recorded_provenance(agent_name) do
    try do
      AgentOS.StateStore.snapshot("provenance")[agent_name]
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp gate_breach_flagged?(agent_name, opts) do
    conformance_store = Keyword.get(opts, :conformance_store, "conformance")

    try do
      case AgentOS.StateStore.snapshot(conformance_store)[agent_name] do
        %AgentOS.ConformanceAuditor.Verdict{status: :flagged, flags: flags} ->
          Enum.any?(flags, fn flag -> flag.type == :gate_breach end)

        _ ->
          false
      end
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp normalize_mode("--always-review"), do: :always_review
  defp normalize_mode("always-review"), do: :always_review
  defp normalize_mode(:always_review), do: :always_review
  defp normalize_mode("--review-if-risky"), do: :review_if_risky
  defp normalize_mode("review-if-risky"), do: :review_if_risky
  defp normalize_mode(:review_if_risky), do: :review_if_risky
  defp normalize_mode("--dangerously-skip-review"), do: :dangerously_skip_review
  defp normalize_mode("dangerously-skip-review"), do: :dangerously_skip_review
  defp normalize_mode(:dangerously_skip_review), do: :dangerously_skip_review
  defp normalize_mode(_), do: :always_review
end
