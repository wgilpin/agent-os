defmodule AgentOS.OutputCheck do
  @moduledoc """
  v0 minimal check — drops and logs ungranted actions.
  Deterministic gate enforcement is a Phase 3 concern (DEC-deterministic-gate-is-the-firewall).

  This module verifies that the agent-proposed actions are well-formed maps containing
  a `"type"` key, and that the action type is explicitly allowed by the manifest's
  `"outputs"` or `"connectors"` lists. Ungranted or malformed actions are dropped and
  logged with warnings.
  """

  require Logger

  @doc """
  Validates a list of proposed actions against a parsed manifest map.

  ## Parameters
    - `actions`: The value returned by the agent. Expected to be a list of maps.
    - `manifest`: The parsed manifest map.

  ## Returns
    - `{:ok, list_of_accepted_actions}`
  """
  @spec validate(any(), map()) :: {:ok, [map()]}

  # This clause matches only when `actions` is a list and `manifest` is a map.
  # Elixir uses multiple function clauses with guard clauses (`when ...`) to route execution.
  def validate(actions, manifest) when is_list(actions) and is_map(manifest) do
    # Combine manifest outputs and connectors list, and build a MapSet (hash set)
    # for O(1) membership lookup. Map.get/2 is used with a fallback to avoid nil errors.
    allowed =
      MapSet.new(
        (Map.get(manifest, "outputs") || []) ++
          (Map.get(manifest, "connectors") || [])
      )

    # Filter actions. If the anonymous function returns true, the item is kept;
    # if false, the item is dropped from the list.
    accepted =
      Enum.filter(actions, fn action ->
        # `cond do` is like an if-elif-else chain in Python.
        # It evaluates each branch in order and executes the first truthy condition.
        cond do
          # 1. Action is not a map -> drop and log
          not is_map(action) ->
            Logger.warning("dropped proposed action: bad_shape (not a map): #{inspect(action)}")
            false

          # 2. Action is a map but doesn't have the string key "type" -> drop and log
          not Map.has_key?(action, "type") ->
            Logger.warning(
              "dropped proposed action: no_type (missing type key): #{inspect(action)}"
            )

            false

          # 3. Action type is not in the allowed MapSet -> drop and log
          not MapSet.member?(allowed, Map.get(action, "type")) ->
            type = Map.get(action, "type")

            Logger.warning(
              "dropped proposed action: ungranted (type '#{type}' not allowed by manifest)"
            )

            false

          # 4. Fallback branch (else): action is valid. Keep it.
          true ->
            true
        end
      end)

    # Return a success tuple wrapping the accepted actions.
    {:ok, accepted}
  end

  # Fallback clause matched if `actions` is not a list.
  # Prefixed variable name `_manifest` tells compiler it is intentionally unused.
  def validate(actions, _manifest) do
    Logger.warning(
      "dropped proposed actions: not_a_list (actions must be a list): #{inspect(actions)}"
    )

    {:ok, []}
  end
end
