defmodule AgentOS.AgentLifecycle do
  @moduledoc """
  The single substrate-side seam for per-agent lifecycle controls exposed on the inventory
  page (spec 042): pause, resume, delete, and editing of spend cap and triggers.

  Trigger-editing semantics: `update_triggers/3` replaces the agent's full trigger list
  (add/remove/retype in one atomic edit) and re-arms so time changes take effect without a
  restart. A `startup` trigger added or kept by an edit does NOT fire on the edit itself —
  startup fires only at deploy completion and at boot re-arming (an edit is not a deploy).

  The web layer (`AgentOSWeb.InventoryLive`) calls ONLY this module — it never touches the
  deployment registry, the filesystem, the manifest, or the state stores directly. Keeping the
  writes here preserves Constitution IX: deployment-record writes stay inside
  `AgentOS.DeploymentRegistry` (the sole writer to `"deployments"`), and this module simply
  orchestrates that registry plus `TriggerArming`, the manifest projection, and the per-agent
  state stores.

  Every function returns `:ok | {:error, reason}` so the LiveView can flash failures without
  interpreting internals.

  Substrate-owned agents (config `:agent_os, :system_agents`, e.g. the discovery agent) are
  off-limits to every mutation here — they are managed by config/code, their manifests may
  carry fields (mounts) the serializer does not round-trip, and their files can be tracked
  test fixtures. All functions return `{:error, :system_agent}` for them, and the inventory
  UI hides them via `system_agent?/1`.

  Path/collaborator overrides (all optional, defaulted for production, injected in tests):
    * `:manifest_path` — the agent's manifest file (default `"manifests/<name>.md"`).
    * `:agents_dir`    — root of the generated-agent code tree (default `"agents"`).
    * `:trigger_server` — the `TriggerArming` process (default `AgentOS.TriggerArming`).
  """

  require Logger

  alias AgentOS.DeploymentRegistry
  alias AgentOS.Manifest
  alias AgentOS.StateStore
  alias AgentOS.TriggerArming

  # Per-agent state stores wiped on delete. Each keys entries by agent_name at the top level,
  # so a single {:delete_in, [name]} removes the agent's slice. "pending_approvals" is handled
  # separately (nested under [:approvals, ref]); "data/run_log.md" is global history, kept.
  @per_agent_stores ~w(spend_ledger provenance conformance judge_results security_review_results check_reruns)

  @doc """
  True for substrate-owned agents (config `:agent_os, :system_agents`): hidden from the
  inventory UI and refused by every lifecycle mutation.
  """
  @spec system_agent?(String.t()) :: boolean()
  def system_agent?(agent_name) when is_binary(agent_name) do
    agent_name in Application.get_env(:agent_os, :system_agents, [])
  end

  @doc """
  Pauses an agent: marks its deployment record inactive so EVERY trigger path (time, event,
  message, startup) refuses to fire it, reversibly and durably. Errors if the agent was never
  deployed (no record to pause). Idempotent on an already-paused agent.
  """
  @spec pause(String.t()) :: :ok | {:error, :not_deployed | :system_agent}
  def pause(agent_name) when is_binary(agent_name) do
    cond do
      system_agent?(agent_name) -> {:error, :system_agent}
      is_nil(DeploymentRegistry.get(agent_name)) -> {:error, :not_deployed}
      true -> DeploymentRegistry.mark_inactive(agent_name)
    end
  end

  @doc """
  Resumes a paused agent: restores its deployment record to active (preserving the original
  `deployed_at`/provenance) and re-arms its time triggers from the current manifest. Resume is
  NOT a redeploy — the startup trigger deliberately does not fire. Errors if the agent has no
  record, or if the manifest file backing the record has gone missing (fail loudly rather than
  reactivate an unrunnable agent).
  """
  @spec resume(String.t(), keyword()) ::
          :ok | {:error, :not_deployed | :manifest_missing | :system_agent}
  def resume(agent_name, opts \\ []) when is_binary(agent_name) do
    case {system_agent?(agent_name), DeploymentRegistry.get(agent_name)} do
      {true, _record} ->
        {:error, :system_agent}

      {false, nil} ->
        {:error, :not_deployed}

      {false, record} ->
        path = Keyword.get(opts, :manifest_path, record.manifest_path)

        if File.exists?(path) do
          :ok = DeploymentRegistry.mark_active(agent_name)
          # Re-arm from the current manifest; startup is intentionally NOT fired (resume is
          # not a deploy). rearm arms only because the record is now active.
          safe_trigger(opts, :rearm, agent_name)
          :ok
        else
          Logger.warning(
            "AgentLifecycle: resume for #{inspect(agent_name)} aborted — manifest missing at " <>
              "#{inspect(path)}"
          )

          {:error, :manifest_missing}
        end
    end
  end

  @doc """
  Starts one run of the agent immediately (trigger label "manual"), through the same
  deployed-and-active gate as every other dispatch path — a paused or undeployed agent
  cannot be run. The run is asynchronous (ephemeral subprocess via `RunSupervisor`);
  `:ok` means it was started, not that it finished.
  """
  @spec run_now(String.t(), keyword()) ::
          :ok | {:error, :system_agent | :not_active | :code_missing | :awaiting_approval}
  def run_now(agent_name, opts \\ []) when is_binary(agent_name) do
    start_run_fn = Keyword.get(opts, :start_run_fn, &AgentOS.RunSupervisor.start_run/1)
    agents_dir = Keyword.get(opts, :agents_dir, "agents")

    cond do
      system_agent?(agent_name) ->
        {:error, :system_agent}

      not DeploymentRegistry.deployed_and_active?(agent_name) ->
        {:error, :not_active}

      # An orphaned manifest (code never generated, or deleted by hand) can be
      # deployed but not run — fail with a message instead of a python errno.
      not File.exists?(Path.join([agents_dir, agent_name, "main.py"])) ->
        {:error, :code_missing}

      # A run that would only park on human approval is refused up front: the UI
      # offers "Approve to run" (request_approval/2 + the consent page) instead.
      run_needs_approval?(agent_name, opts) ->
        {:error, :awaiting_approval}

      true ->
        Logger.info("AgentLifecycle: manual run requested for #{inspect(agent_name)}")
        start_run_fn.(trigger: "manual", agent: agent_name)
        :ok
    end
  end

  @doc """
  Parks (or reuses) the pending human approval for an agent whose current manifest +
  code is not yet approved, WITHOUT running it — the inventory "Approve to run"
  affordance. Returns `{:ok, %{ref: ref | :already_approved, manifest_path: path}}`
  so the caller can send the human straight to that agent's consent page, or
  `{:error, reason}`.
  """
  @spec request_approval(String.t(), keyword()) ::
          {:ok, %{ref: String.t() | :already_approved, manifest_path: String.t()}}
          | {:error, term()}
  def request_approval(agent_name, opts \\ []) when is_binary(agent_name) do
    if system_agent?(agent_name) do
      {:error, :system_agent}
    else
      mpath = effective_manifest_path(agent_name, opts)

      case AgentOS.Provisioner.deploy(mpath, configured_review_mode(opts), opts) do
        {:blocked, ref} -> {:ok, %{ref: ref, manifest_path: mpath}}
        {:ok, _status} -> {:ok, %{ref: :already_approved, manifest_path: mpath}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp run_needs_approval?(agent_name, opts) do
    AgentOS.Provisioner.approval_required?(
      effective_manifest_path(agent_name, opts),
      configured_review_mode(opts)
    )
  end

  defp configured_review_mode(opts) do
    Keyword.get(opts, :review_mode) ||
      Application.get_env(:agent_os, :review_mode, :always_review)
  end

  # Same resolution order the run itself uses (run_worker): explicit override,
  # then the deployment record's path, then the conventional location.
  defp effective_manifest_path(agent_name, opts) do
    case Keyword.get(opts, :manifest_path) do
      path when is_binary(path) ->
        path

      nil ->
        case DeploymentRegistry.get(agent_name) do
          %{manifest_path: path} when is_binary(path) -> path
          _ -> Path.join("manifests", "#{agent_name}.md")
        end
    end
  end

  @doc """
  Permanently deletes an agent and everything that belongs to it. Order matters: dispatch is
  gated off FIRST (registry delete), then armed timers are cancelled, then files and per-agent
  state are removed — so no run can start once the delete is accepted (FR-007). Tolerant of
  partially-missing files/keys (logs and continues) and idempotent. The global
  `data/run_log.md` history is intentionally left intact (FR-008). Returns `:ok` for any
  non-system agent.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, :system_agent}
  def delete(agent_name, opts \\ []) when is_binary(agent_name) do
    if system_agent?(agent_name) do
      {:error, :system_agent}
    else
      do_delete(agent_name, opts)
    end
  end

  defp do_delete(agent_name, opts) do
    record = DeploymentRegistry.get(agent_name)
    manifest_path = Keyword.get(opts, :manifest_path, manifest_path(agent_name, record))
    agents_dir = Keyword.get(opts, :agents_dir, "agents")

    # 1. Gate all future dispatch immediately.
    :ok = DeploymentRegistry.delete(agent_name)

    # 2. Cancel any armed daily timers (future firings).
    safe_trigger(opts, :disarm, agent_name)

    # 3. Remove the agent's code dir and manifest; missing paths are fine (idempotent cleanup).
    delete_files(agent_name, agents_dir, manifest_path)

    # 4. Wipe per-agent runtime state stores.
    Enum.each(@per_agent_stores, fn store ->
      safe_state(fn -> StateStore.apply_action(store, {:delete_in, [agent_name]}) end, store)
    end)

    # 5. Sweep pending approvals owned by this agent.
    sweep_pending_approvals(agent_name)

    :ok
  end

  @doc """
  Sets the agent's daily spend cap from a positive dollar amount, persisting it to the manifest
  in micro-dollars. The gate re-reads the manifest per evaluation, so the new cap takes effect on
  the next spend check with no restart. Accumulated spend in the ledger is untouched. Rejects
  zero/negative/non-numeric input with no side effects.
  """
  @spec update_spend_cap(String.t(), term(), keyword()) ::
          :ok | {:error, :invalid_cap | term()}
  def update_spend_cap(agent_name, dollars, opts \\ []) when is_binary(agent_name) do
    cond do
      system_agent?(agent_name) ->
        {:error, :system_agent}

      is_number(dollars) and dollars > 0 ->
        path = Keyword.get(opts, :manifest_path, manifest_path(agent_name, nil))

        with {:ok, manifest} <- Manifest.load(path) do
          # Store the cap in micro-dollars (dollars * 1_000_000), matching the projection.
          updated = put_in(manifest.spend.cap, round(dollars * 1_000_000))
          Manifest.Projection.write(updated, path)
        end

      true ->
        {:error, :invalid_cap}
    end
  end

  @doc """
  Replaces the agent's trigger list wholesale: add, remove, and retype triggers in one edit.
  `triggers` is the full desired list; entries may carry atom or string keys (manifest shape
  or raw form params). Allowed types exactly: `startup`, `time` (requires a valid "HH:MM"
  `at`, 00:00–23:59), `event` (requires a non-empty `name`), `message` (no params).

  Validation is atomic: any invalid entry or duplicate trigger rejects the WHOLE edit with no
  side effects. An empty list is allowed — the agent becomes inert until re-edited (success,
  not an error).

  After persisting, re-arms the agent so removed/retyped time triggers stop firing and newly
  added times arm immediately, with no restart. Adding or keeping a `startup` trigger does
  NOT fire it on the edit — startup fires only at deploy completion and at boot re-arming.
  """
  @spec update_triggers(String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def update_triggers(agent_name, triggers, opts \\ [])
      when is_binary(agent_name) and is_list(triggers) do
    if system_agent?(agent_name) do
      {:error, :system_agent}
    else
      path = Keyword.get(opts, :manifest_path, manifest_path(agent_name, nil))

      with {:ok, normalized} <- normalize_triggers(triggers),
           {:ok, manifest} <- Manifest.load(path) do
        updated = %{manifest | triggers: normalized}

        case Manifest.Projection.write(updated, path) do
          :ok ->
            # Re-arm from the new manifest: removed/retyped times stop firing, new times fire
            # (FR-010). Startup is deliberately NOT fired here — an edit is not a deploy.
            safe_trigger(opts, :rearm, agent_name)
            :ok

          error ->
            error
        end
      end
    end
  end

  # --- Helpers ---

  # The manifest path for an agent: the deployment record's path when available, else the
  # conventional "manifests/<name>.md" (inventory scans manifests/*.md).
  defp manifest_path(_agent_name, %{manifest_path: path}) when is_binary(path), do: path
  defp manifest_path(agent_name, _), do: Path.join("manifests", "#{agent_name}.md")

  # Removes the agent's code directory and manifest file, tolerating either being already gone.
  defp delete_files(agent_name, agents_dir, manifest_path) do
    agent_dir = Path.join(agents_dir, agent_name)

    case File.rm_rf(agent_dir) do
      {:ok, _} ->
        :ok

      {:error, reason, _} ->
        Logger.warning(
          "AgentLifecycle: could not fully remove #{inspect(agent_dir)}: #{inspect(reason)}"
        )
    end

    case File.rm(manifest_path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "AgentLifecycle: could not remove #{inspect(manifest_path)}: #{inspect(reason)}"
        )
    end
  end

  # Deletes every pending-approval entry OWNED by this agent: those addressed to it, or a
  # deploy approval for its manifest. (Ownership only — unlike the inventory display filter,
  # this must not sweep approvals with a nil recipient or a merely-shared connector type.)
  defp sweep_pending_approvals(agent_name) do
    safe_state(
      fn ->
        approvals =
          "pending_approvals"
          |> StateStore.snapshot()
          |> Map.get(:approvals, %{})

        approvals
        |> Enum.filter(fn {_ref, entry} -> owns_approval?(entry, agent_name) end)
        |> Enum.each(fn {ref, _entry} ->
          StateStore.apply_action("pending_approvals", {:delete_in, [:approvals, ref]})
        end)
      end,
      "pending_approvals"
    )
  end

  # True when a pending-approval entry belongs to `agent_name`.
  defp owns_approval?(%{action: action}, agent_name) do
    recipient = field(action, :recipient)
    type = field(action, :type)
    method = field(action, :method)

    recipient == agent_name or
      (type == "deploy" and is_binary(method) and Path.basename(method, ".md") == agent_name)
  end

  defp owns_approval?(_entry, _agent_name), do: false

  # Reads a field from an action whether it is a struct/atom-keyed map or a string-keyed map.
  defp field(action, key) when is_map(action) do
    Map.get(action, key) || Map.get(action, to_string(key))
  end

  defp field(_action, _key), do: nil

  # Normalizes and validates a full trigger list atomically: every entry must be valid and
  # the result free of duplicates, or the whole edit is rejected with the first error.
  defp normalize_triggers(triggers) do
    normalized =
      Enum.reduce_while(triggers, {:ok, []}, fn raw, {:ok, acc} ->
        case normalize_trigger(raw) do
          {:ok, trigger} -> {:cont, {:ok, [trigger | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, reversed} <- normalized do
      list = Enum.reverse(reversed)

      # Two identical triggers would double-fire (and double-arm) — reject the edit.
      if Enum.uniq(list) == list do
        {:ok, list}
      else
        {:error, :duplicate_triggers}
      end
    end
  end

  # Normalizes one raw trigger (atom- or string-keyed) into the manifest shape, validating
  # its type-specific fields. Extra keys (e.g. a leftover `at` on a retyped row) are dropped.
  defp normalize_trigger(raw) when is_map(raw) do
    case field(raw, :type) do
      type when type in ["time", :time] ->
        at = field(raw, :at)
        if valid_time?(at), do: {:ok, %{type: :time, at: at}}, else: {:error, {:invalid_time, at}}

      type when type in ["event", :event] ->
        name = field(raw, :name)

        if is_binary(name) and String.trim(name) != "" do
          {:ok, %{type: :event, name: String.trim(name)}}
        else
          {:error, :invalid_event_name}
        end

      type when type in ["message", :message] ->
        {:ok, %{type: :message}}

      type when type in ["startup", :startup] ->
        {:ok, %{type: :startup}}

      other ->
        {:error, {:unknown_trigger_type, other}}
    end
  end

  defp normalize_trigger(other), do: {:error, {:unknown_trigger_type, other}}

  defp valid_time?(at) when is_binary(at) do
    case String.split(at, ":") do
      [h, m] ->
        with {hour, ""} <- Integer.parse(h),
             {minute, ""} <- Integer.parse(m) do
          hour in 0..23 and minute in 0..59
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_time?(_), do: false

  # Calls TriggerArming (disarm/rearm) tolerantly: in a minimal test tree the process may not
  # be running, in which case the timer is a no-op rather than a crash. In production the
  # supervised process is always up.
  defp safe_trigger(opts, fun, agent_name) do
    server = Keyword.get(opts, :trigger_server, TriggerArming)

    try do
      apply(TriggerArming, fun, [agent_name, server])
    catch
      :exit, reason ->
        Logger.warning(
          "AgentLifecycle: TriggerArming.#{fun} for #{inspect(agent_name)} unavailable: " <>
            "#{inspect(reason)} — continuing"
        )

        :ok
    end
  end

  # Runs a state-store mutation tolerantly: a store absent in a minimal test tree logs rather
  # than crashing the whole delete (Constitution VI — loud, never silent).
  defp safe_state(fun, store) do
    fun.()
  rescue
    error ->
      Logger.warning(
        "AgentLifecycle: state op on #{store} failed: #{inspect(error)} — continuing"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "AgentLifecycle: state op on #{store} unavailable: #{inspect(reason)} — continuing"
      )

      :ok
  end
end
