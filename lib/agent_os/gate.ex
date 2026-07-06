defmodule AgentOS.Gate do
  @moduledoc """
  Pure deterministic safety gate for proposed actions.
  """

  require Logger
  alias AgentOS.ProposedAction
  alias AgentOS.Manifest
  alias AgentOS.Manifest.Grant

  @doc """
  Evaluates a single ProposedAction against the manifest, connector registry, and spend.
  """
  @spec evaluate(ProposedAction.t(), Manifest.t(), map(), map()) ::
          {:approve, Grant.t()}
          | {:needs_approval, Grant.t()}
          | {:reject, atom()}
          | {:breach, :spend}
  def evaluate(%ProposedAction{} = action, %Manifest{} = manifest, registry, %{spent: spent}) do
    # 1. Grant match
    action_handle =
      Map.get(action.payload || %{}, "handle") || Map.get(action.payload || %{}, :handle)

    case Enum.find(manifest.grants, fn g ->
           g.connector == action.type and
             (is_nil(g.handle) or g.handle == action_handle)
         end) do
      nil ->
        Logger.warning(
          "dropped proposed action: ungranted (type '#{action.type}' not allowed by manifest)"
        )

        {:reject, :unknown_action}

      grant ->
        # 2. Recipient scope
        cond do
          grant.recipients != nil and action.recipient not in grant.recipients ->
            Logger.warning(
              "dropped proposed action: recipient_out_of_scope (type '#{action.type}', recipient '#{action.recipient}')"
            )

            {:reject, :recipient_out_of_scope}

          # 3. Method scope
          grant.methods != nil and action.method not in grant.methods ->
            Logger.warning(
              "dropped proposed action: method_out_of_scope (type '#{action.type}', method '#{action.method}')"
            )

            {:reject, :method_out_of_scope}

          true ->
            # Look up registry danger metadata
            case Map.get(registry, action.type) do
              nil ->
                Logger.warning(
                  "dropped proposed action: unknown_action in registry (type '#{action.type}')"
                )

                {:reject, :unknown_action}

              connector ->
                # 4. Spend check
                cost = Map.get(connector, :cost, 0)

                if spent + cost > manifest.spend.cap do
                  Logger.warning(
                    "breached spend cap: type '#{action.type}' with cost #{to_dollars(cost)} exceeds cap #{to_dollars(manifest.spend.cap)} (spent: #{to_dollars(spent)})"
                  )

                  {:breach, :spend}
                else
                  # 5. Approval check
                  if Map.get(connector, :requires_runtime_approval?, false) do
                    {:needs_approval, grant}
                  else
                    {:approve, grant}
                  end
                end
            end
        end
    end
  end

  @doc """
  Partitions a batch of raw actions (maps) into:
  {approved, parked, rejected, breached}
  """
  @spec partition_batch([map()], Manifest.t(), map(), map()) ::
          {[%{action: ProposedAction.t(), grant: Grant.t()}],
           [%{action: ProposedAction.t(), grant: Grant.t()}], [{map(), atom()}],
           [ProposedAction.t()]}
  def partition_batch(actions, %Manifest{} = manifest, registry, %{spent: initial_spent}) do
    {approved, parked, rejected, breached, _spent} =
      Enum.reduce(actions, {[], [], [], [], initial_spent}, fn raw_action,
                                                               {app, park, rej, bre, cur_spent} ->
        case ProposedAction.from_map(raw_action) do
          {:error, :bad_shape} ->
            Logger.warning(
              "dropped proposed action: bad_shape (not a map or missing type): #{inspect(raw_action)}"
            )

            {app, park, [{raw_action, :bad_shape} | rej], bre, cur_spent}

          {:ok, action} ->
            case evaluate(action, manifest, registry, %{spent: cur_spent}) do
              {:approve, grant} ->
                cost = get_cost(action.type, registry)

                action = %{
                  action
                  | grant_resolved_namespace: grant.namespace,
                    grant_resolved_path: grant.path
                }

                {[%{action: action, grant: grant} | app], park, rej, bre, cur_spent + cost}

              {:needs_approval, grant} ->
                cost = get_cost(action.type, registry)

                action = %{
                  action
                  | grant_resolved_namespace: grant.namespace,
                    grant_resolved_path: grant.path
                }

                {app, [%{action: action, grant: grant} | park], rej, bre, cur_spent + cost}

              {:reject, reason} ->
                {app, park, [{raw_action, reason} | rej], bre, cur_spent}

              {:breach, :spend} ->
                {app, park, rej, [action | bre], cur_spent}
            end
        end
      end)

    {Enum.reverse(approved), Enum.reverse(parked), Enum.reverse(rejected), Enum.reverse(breached)}
  end

  defp get_cost(type, registry) do
    case Map.get(registry, type) do
      nil -> 0
      conn -> Map.get(conn, :cost, 0)
    end
  end

  defp to_dollars(microdollars) do
    "$" <> :erlang.float_to_binary(microdollars / 1_000_000, [{:decimals, 6}, :compact])
  end
end
