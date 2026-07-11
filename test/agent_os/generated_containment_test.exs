defmodule AgentOS.GeneratedContainmentTest do
  # Adversarial containment probe (FR-008 / US2 / SC-002): a hostile generated body run
  # under the generated-agent runtime image with its code mounted READ-ONLY cannot read a
  # host file outside its mounts, open an outbound connection, or write outside /scratch.
  # Modelled on isolation_test.exs; not async (touches the docker daemon).
  use ExUnit.Case, async: false

  alias AgentOS.Sandbox
  alias AgentOS.PortRunner

  @image "agent-generated:dev"
  @probe_host_dir Path.expand("test/fixtures/agents/containment_probe")

  setup do
    cidfile = Path.join(System.tmp_dir!(), "cidfile_#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm(cidfile) end)
    {:ok, cidfile: cidfile}
  end

  # Runs the probe body in `mode` inside the generated-agent sandbox with the fixture
  # mounted read-only, exactly as dispatch_spec/3 would mount a real generated body.
  defp run_probe(cidfile, mode, extra_args) do
    sandbox = %Sandbox{
      image: @image,
      cidfile: cidfile,
      network: "none",
      memory_mb: 128,
      cpus: "0.5",
      user: "1000:1000",
      entrypoint: "/app/.venv/bin/python",
      cmd_args: ["/app/agents/containment_probe/main.py", mode | extra_args],
      mounts: [{@probe_host_dir, "/app/agents/containment_probe:ro"}]
    }

    PortRunner.run("{}", "docker", Sandbox.build_argv(sandbox))
  end

  @tag :docker
  test "reading a host file outside the mounts is denied", %{cidfile: cidfile} do
    # A host path that exists on the host but is not mounted into the container.
    host_path = Path.expand("mix.exs")
    # Denied ⇒ non-zero exit (the error tuple is the surfaced, non-swallowed signal — AC4).
    assert {:error, {:exit_status, _code}} = run_probe(cidfile, "read", [host_path])
  end

  @tag :docker
  test "opening an outbound network connection is refused", %{cidfile: cidfile} do
    assert {:error, {:exit_status, _code}} = run_probe(cidfile, "net", [])
  end

  @tag :docker
  test "writing outside /scratch (into the read-only code mount) is denied", %{cidfile: cidfile} do
    assert {:error, {:exit_status, _code}} = run_probe(cidfile, "write", [])
  end

  @tag :docker
  test "positive control: the probe's own /scratch write succeeds (sandbox is live)", %{
    cidfile: cidfile
  } do
    # Proves the failures above are containment, not a broken image: a write to the one
    # legitimately-writable surface (/scratch) succeeds.
    sandbox = %Sandbox{
      image: @image,
      cidfile: cidfile,
      network: "none",
      memory_mb: 128,
      cpus: "0.5",
      user: "1000:1000",
      entrypoint: "/bin/sh",
      cmd_args: ["-c", "echo ok > /scratch/probe.txt && cat /scratch/probe.txt"],
      mounts: [{@probe_host_dir, "/app/agents/containment_probe:ro"}]
    }

    assert {:ok, stdout} = PortRunner.run("{}", "docker", Sandbox.build_argv(sandbox))
    assert stdout =~ "ok"
  end
end
