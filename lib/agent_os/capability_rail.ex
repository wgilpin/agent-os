defmodule AgentOS.CapabilityRail do
  @moduledoc """
  The deterministic capability rail that evaluates tool calls against the agent's manifest.
  Blocks ungranted calls, logs to the action transcript, and isolates tool execution.
  """

  require Logger

  alias AgentOS.StateStore
  alias AgentOS.ActionTranscript
  alias AgentOS.ActionTranscript.Entry

  @doc """
  Iterates through tool calls, evaluating them against grants and spending caps.
  Appends ActionTranscript entries for both granted and rejected calls.
  Returns `{:ok, tool_messages, accumulated_cost}` or `{:breach, :spend}`.
  """
  def evaluate_tool_calls(tool_calls, agent_name, manifest, run_token) do
    registry = AgentOS.Connector.registry()

    Enum.reduce_while(tool_calls, {:ok, [], 0}, fn tool_call, {:ok, msg_acc, cost_acc} ->
      tool_name = get_in(tool_call, ["function", "name"]) || get_in(tool_call, [:function, :name])
      tool_call_id = Map.get(tool_call, "id") || Map.get(tool_call, :id)

      args_str =
        get_in(tool_call, ["function", "arguments"]) || get_in(tool_call, [:function, :arguments])

      args =
        case Jason.decode(args_str) do
          {:ok, decoded} -> decoded
          {:error, _} -> %{}
        end

      # Sandbox check: is the tool explicitly granted?
      grant = Enum.find(manifest.grants, fn g -> g.connector == tool_name end)
      
      method = Map.get(args, "method") || Map.get(args, :method)
      
      method_granted? =
        cond do
          grant == nil -> false
          grant.methods != nil and is_binary(method) -> method in grant.methods
          true -> true
        end

      cond do
        grant == nil ->
          Logger.error("Sandbox blocked ungranted tool: '#{tool_name}'")

          ActionTranscript.append(
            run_token,
            Entry.new(%{
              kind: :rejected,
              connector: tool_name,
              method: method,
              arguments: args,
              result: nil,
              reason_code: :ungranted_connector
            })
          )

          msg = %{
            "role" => "tool",
            "tool_call_id" => tool_call_id,
            "name" => tool_name,
            "content" => "Error: unauthorized tool '#{tool_name}'"
          }

          {:cont, {:ok, msg_acc ++ [msg], cost_acc}}
          
        not method_granted? ->
          Logger.error("Sandbox blocked ungranted method: '#{method}' for tool '#{tool_name}'")

          ActionTranscript.append(
            run_token,
            Entry.new(%{
              kind: :rejected,
              connector: tool_name,
              method: method,
              arguments: args,
              result: nil,
              reason_code: :ungranted_method
            })
          )

          msg = %{
            "role" => "tool",
            "tool_call_id" => tool_call_id,
            "name" => tool_name,
            "content" => "Error: unauthorized method '#{method}' for tool '#{tool_name}'"
          }

          {:cont, {:ok, msg_acc ++ [msg], cost_acc}}

        true ->
        case Map.fetch(registry, tool_name) do
          {:ok, cap} ->
            tool_cost = Map.get(cap, :cost, 0)

            # Spend ledger lookup prior to tool call
            ledger = StateStore.snapshot("spend_ledger")
            raw_entry = Map.get(ledger, agent_name, %{spent: 0})
            current_spent = raw_entry.spent + cost_acc

            if current_spent + tool_cost >= manifest.spend.cap do
              Logger.warning("Spend cap exceeded before executing tool '#{tool_name}'")
              {:halt, {:breach, :spend}}
            else
              # Resolve mode from broker
              mode = case AgentOS.InferenceBroker.resolve(run_token) do
                {:ok, reg} -> reg.mode
                _ -> :live
              end

              cond do
                mode == :record ->
                # Record mode: append synthetic success, no actual execution, zero cost.
                res = %{"status" => "recorded"}
                ActionTranscript.append(
                  run_token,
                  Entry.new(%{
                    kind: :granted,
                    connector: tool_name,
                    method: method,
                    arguments: args,
                    result: res,
                    reason_code: nil
                  })
                )

                res_str = Jason.encode!(res)
                msg = %{
                  "role" => "tool",
                  "tool_call_id" => tool_call_id,
                  "name" => tool_name,
                  "content" => res_str
                }

                {:cont, {:ok, msg_acc ++ [msg], cost_acc}} # Notice cost_acc remains unchanged (tool_cost not added)

                Map.get(cap, :requires_runtime_approval?, false) ->
                  # Approval-required connector: DO NOT execute. Record the call as
                  # :parked and queue it for human approval in the same shape the
                  # approval-resume path (TriggerGateway -> Effector.act/1) consumes.
                  action = %AgentOS.ProposedAction{
                    type: tool_name,
                    method: method || (grant.methods && List.first(grant.methods)),
                    recipient:
                      Map.get(args, "recipient") ||
                        (grant.recipients && List.first(grant.recipients)),
                    payload: args
                  }

                  ref = "ref_#{System.unique_integer([:positive])}"

                  approvals =
                    case StateStore.snapshot("pending_approvals") do
                      %{} = store -> Map.get(store, :approvals, %{})
                      _ -> %{}
                    end

                  StateStore.apply_action(
                    "pending_approvals",
                    {:put, :approvals,
                     Map.put(approvals, ref, %{ref: ref, action: action, grant: grant})}
                  )

                  ActionTranscript.append(
                    run_token,
                    Entry.new(%{
                      kind: :parked,
                      connector: tool_name,
                      method: action.method,
                      arguments: args,
                      result: nil,
                      reason_code: nil
                    })
                  )

                  Logger.info(
                    "Capability rail parked approval-required tool '#{tool_name}' for human approval (ref=#{ref})"
                  )

                  park_msg = %{
                    "role" => "tool",
                    "tool_call_id" => tool_call_id,
                    "name" => tool_name,
                    "content" => "Queued for human approval; not executed (pending approval)."
                  }

                  {:cont, {:ok, msg_acc ++ [park_msg], cost_acc}}

                true ->
                {:ok, mod} = AgentOS.Connector.get_module(tool_name)
                credential_id = Map.get(cap, :credential)

                # Execute dynamic tool isolated and timeboxed
                tool_exec_result =
                  if credential_id do
                    AgentOS.CredentialProxy.with_credential(credential_id, fn secret ->
                      execute_tool_isolated(mod, args, secret)
                    end)
                  else
                    execute_tool_isolated(mod, args, nil)
                  end

                case tool_exec_result do
                  {:ok, res} ->
                    ActionTranscript.append(
                      run_token,
                      Entry.new(%{
                        kind: :granted,
                        connector: tool_name,
                        method: method,
                        arguments: args,
                        result: res,
                        reason_code: nil
                      })
                    )

                    res_str = if is_binary(res), do: res, else: Jason.encode!(res)

                    msg = %{
                      "role" => "tool",
                      "tool_call_id" => tool_call_id,
                      "name" => tool_name,
                      "content" => res_str
                    }

                    {:cont, {:ok, msg_acc ++ [msg], cost_acc + tool_cost}}

                {:error, reason} ->
                  error_result = %{"error" => inspect(reason)}

                  ActionTranscript.append(
                    run_token,
                    Entry.new(%{
                      kind: :granted,
                      connector: tool_name,
                      method: nil,
                      arguments: args,
                      result: error_result,
                      reason_code: nil
                    })
                  )

                  reason_str = "Error: " <> inspect(reason)

                  msg = %{
                    "role" => "tool",
                    "tool_call_id" => tool_call_id,
                    "name" => tool_name,
                    "content" => reason_str
                  }

                  {:cont, {:ok, msg_acc ++ [msg], cost_acc + tool_cost}}
              end
            end
            end

          :error ->
            ActionTranscript.append(
              run_token,
              Entry.new(%{
                kind: :rejected,
                connector: tool_name,
                method: nil,
                arguments: args,
                result: nil,
                reason_code: :unknown_connector
              })
            )

            msg = %{
              "role" => "tool",
              "tool_call_id" => tool_call_id,
              "name" => tool_name,
              "content" => "Error: unknown connector '#{tool_name}'"
            }

            {:cont, {:ok, msg_acc ++ [msg], cost_acc}}
        end
      end
    end)
  end

  # Executes a tool connector inside a timeboxed, crash-isolated dynamic Task
  defp execute_tool_isolated(mod, arguments, secret) do
    # Fallback to local task supervisor if the global registry one is missing
    supervisor =
      case Process.whereis(AgentOS.ConnectorSupervisor) do
        nil ->
          {:ok, pid} = Task.Supervisor.start_link()
          pid

        pid ->
          pid
      end

    if function_exported?(mod, :execute_tool, 2) do
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          try do
            mod.execute_tool(arguments, secret)
          catch
            kind, reason ->
              {:error, {:exception, kind, reason}}
          end
        end)

      case Task.yield(task, 5000) || Task.shutdown(task) do
        {:ok, {:ok, res}} ->
          {:ok, res}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:ok, other} ->
          {:error, other}

        nil ->
          {:error, :timeout}
      end
    else
      {:error, :not_implemented}
    end
  end
end
