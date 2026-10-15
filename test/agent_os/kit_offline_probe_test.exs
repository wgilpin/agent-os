defmodule AgentOS.KitOfflineProbeTest do
  # Feature 046 / US4 (FR-013 / SC-004): in-image offline containment probe. The baked
  # runtime kit runs the golden multi-step task under `--network=none`, reaching its broker
  # ONLY over a UDS on a shared volume — proving zero egress and no lazy asset downloads
  # (tiktoken never fetches). Extends the spec-044 containment posture.
  #
  # Tagged :docker (excluded by default). Requires the `agent-generated:dev` image built
  # from agents/generated.Dockerfile. Run: `mix test --include docker test/agent_os/kit_offline_probe_test.exs`.
  use ExUnit.Case, async: false

  @tag :docker
  @tag timeout: 180_000
  test "the baked sample body completes the golden task offline with zero egress" do
    {out, status} =
      System.cmd("bash", [Path.expand("scripts/kit_offline_probe.sh")], stderr_to_stdout: true)

    assert status == 0, "offline probe failed:\n#{out}"
    assert out =~ "PROBE_OK"
    # Exactly the three commanded calls (search_notes, add_todo, final_result).
    assert out =~ "PROBE_BROKER_REQUESTS=3"
  end
end
