defmodule AgentOS.ApplicationBootGuardTest do
  # Feature 045, FR-011/SC-007: the substrate runs only containerized on macOS. This exercises the
  # pure decision function directly so the refusal logic is proven without actually aborting the
  # (autostart-disabled) test VM's application start.
  use ExUnit.Case, async: true

  alias AgentOS.Application, as: App

  describe "boot_permitted?/3" do
    test "refuses a real app start on the macOS host outside the container" do
      assert {:refused, message} = App.boot_permitted?(true, false, {:unix, :darwin})
      # The message must name the container entry point (loud + diagnosable, Constitution VI).
      assert message =~ "docker compose up substrate"
      assert message =~ "containerized"
    end

    test "permits the containerized substrate (AOS_IN_CONTAINER set) on macOS" do
      assert :ok == App.boot_permitted?(true, true, {:unix, :darwin})
    end

    test "permits any start when autostart is disabled (the hermetic test suite)" do
      # This is the invariant that keeps `mix test` on the host unaffected by the guard.
      assert :ok == App.boot_permitted?(false, false, {:unix, :darwin})
      assert :ok == App.boot_permitted?(false, true, {:unix, :darwin})
    end

    test "permits a host start on non-macOS (Linux host / CI)" do
      assert :ok == App.boot_permitted?(true, false, {:unix, :linux})
    end
  end
end
