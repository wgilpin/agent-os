defmodule AgentOS.DeploymentDispatchTest do
  @moduledoc """
  T009/T020: trigger dispatch consults the deployment registry — only registered,
  active agents fire; refusals are observable (FR-006). The inventory test-fire
  routes through this exact dispatch path (US4).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AgentOS.DeploymentRegistry
  alias AgentOS.TriggerGateway

  setup do
    AgentOS.TestHelper.start_mounts!()
    :ok
  end

  # A manifests_fn stub exposing one agent with an event trigger and a message trigger.
  defp manifests_fn_for(agent_name) do
    manifest = %AgentOS.Manifest{
      purpose: "dispatch test",
      owner: "human",
      supervision: "none",
      grants: [],
      spend: %AgentOS.Manifest.Spend{cap: 1000, window: :daily, on_breach: :kill},
      triggers: [
        %{type: :event, name: "new_bookmarks"},
        %{type: :message}
      ]
    }

    fn -> %{agent_name => manifest} end
  end

  # Collects start_run_fn invocations in an Agent for assertion.
  defp recording_start_run do
    {:ok, holder} = Agent.start_link(fn -> [] end)

    fired = fn opts ->
      Agent.update(holder, fn acc -> [opts | acc] end)
      :ok
    end

    {holder, fired}
  end

  describe "US3: event dispatch is registry-gated" do
    test "undeployed agent never fires on a matching event; refusal is logged" do
      agent = "gate_event_#{System.unique_integer([:positive])}"
      {holder, start_run_fn} = recording_start_run()

      log =
        capture_log(fn ->
          assert {:fired, []} =
                   TriggerGateway.submit_sync({:event, "new_bookmarks", %{"x" => 1}},
                     manifests_fn: manifests_fn_for(agent),
                     start_run_fn: start_run_fn
                   )
        end)

      assert Agent.get(holder, & &1) == []
      assert log =~ agent
      assert log =~ "not deployed"
    end

    test "inactive agent never fires on a matching event" do
      agent = "gate_event_inactive_#{System.unique_integer([:positive])}"
      :ok = DeploymentRegistry.record_deployment(agent, "manifests/#{agent}.md", :reviewed_human)
      :ok = DeploymentRegistry.mark_inactive(agent)

      {holder, start_run_fn} = recording_start_run()

      capture_log(fn ->
        assert {:fired, []} =
                 TriggerGateway.submit_sync({:event, "new_bookmarks", %{}},
                   manifests_fn: manifests_fn_for(agent),
                   start_run_fn: start_run_fn
                 )
      end)

      assert Agent.get(holder, & &1) == []
    end

    test "registered active agent fires on a matching event" do
      agent = "gate_event_active_#{System.unique_integer([:positive])}"
      :ok = DeploymentRegistry.record_deployment(agent, "manifests/#{agent}.md", :reviewed_human)

      {holder, start_run_fn} = recording_start_run()

      assert {:fired, [^agent]} =
               TriggerGateway.submit_sync({:event, "new_bookmarks", %{"x" => 1}},
                 manifests_fn: manifests_fn_for(agent),
                 start_run_fn: start_run_fn
               )

      assert [opts] = Agent.get(holder, & &1)
      assert opts[:trigger] == "event:new_bookmarks"
      assert opts[:agent] == agent
    end
  end

  describe "US3: message dispatch is registry-gated" do
    test "undeployed agent is refused with an observable log" do
      agent = "gate_msg_#{System.unique_integer([:positive])}"
      {holder, start_run_fn} = recording_start_run()

      log =
        capture_log(fn ->
          assert {:rejected, :not_deployed} =
                   TriggerGateway.submit_sync({:message, agent, "hello"},
                     manifests_fn: manifests_fn_for(agent),
                     start_run_fn: start_run_fn
                   )
        end)

      assert Agent.get(holder, & &1) == []
      assert log =~ agent
      assert log =~ "not deployed"
    end

    test "inactive agent is refused" do
      agent = "gate_msg_inactive_#{System.unique_integer([:positive])}"
      :ok = DeploymentRegistry.record_deployment(agent, "manifests/#{agent}.md", :reviewed_human)
      :ok = DeploymentRegistry.mark_inactive(agent)

      {holder, start_run_fn} = recording_start_run()

      capture_log(fn ->
        assert {:rejected, :not_deployed} =
                 TriggerGateway.submit_sync({:message, agent, "hello"},
                   manifests_fn: manifests_fn_for(agent),
                   start_run_fn: start_run_fn
                 )
      end)

      assert Agent.get(holder, & &1) == []
    end
  end

  describe "US4: inventory test-fire routes through normal dispatch" do
    test "deployed agent with a message trigger fires with the payload as trigger_input" do
      agent = "testfire_#{System.unique_integer([:positive])}"
      :ok = DeploymentRegistry.record_deployment(agent, "manifests/#{agent}.md", :reviewed_human)

      {holder, start_run_fn} = recording_start_run()

      assert {:fired, [^agent]} =
               TriggerGateway.submit_sync({:message, agent, "test payload"},
                 manifests_fn: manifests_fn_for(agent),
                 start_run_fn: start_run_fn
               )

      assert [opts] = Agent.get(holder, & &1)
      assert opts[:trigger] == "message"
      assert opts[:trigger_input] == "test payload"
      assert opts[:agent] == agent
    end

    test "agent without a message trigger stays refused even when deployed" do
      agent = "testfire_nomsg_#{System.unique_integer([:positive])}"
      :ok = DeploymentRegistry.record_deployment(agent, "manifests/#{agent}.md", :reviewed_human)

      manifest = %AgentOS.Manifest{
        purpose: "no message trigger",
        owner: "human",
        supervision: "none",
        grants: [],
        spend: %AgentOS.Manifest.Spend{cap: 1000, window: :daily, on_breach: :kill},
        triggers: [%{type: :event, name: "something"}]
      }

      {holder, start_run_fn} = recording_start_run()

      capture_log(fn ->
        assert {:rejected, :no_message_trigger} =
                 TriggerGateway.submit_sync({:message, agent, "x"},
                   manifests_fn: fn -> %{agent => manifest} end,
                   start_run_fn: start_run_fn
                 )
      end)

      assert Agent.get(holder, & &1) == []
    end
  end
end
