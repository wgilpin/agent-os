defmodule AgentOS.ManifestTest do
  use ExUnit.Case, async: true

  alias AgentOS.Manifest
  alias AgentOS.Manifest.Grant
  alias AgentOS.Manifest.Spend

  @happy_manifest """
  ---
  purpose: "Surface content from the people-roster"
  triggers:
    - type: startup
    - type: time
      at: "07:00"
    - type: message
    - type: event
      name: "approval_received"
  grants:
    - connector: kv_append
      methods: ["append"]
    - connector: external_send
      recipients: ["owner-inbox"]
      methods: ["send"]
  mounts:
    - roster_trust
  spend:
    cap: 5
    window: daily
    on_breach: kill
  owner: human
  supervision: restart-once-and-alert
  ---
  Some markdown body here.
  """

  test "parses a startup trigger" do
    tmp =
      Path.join(System.tmp_dir!(), "manifest_startup_#{System.unique_integer([:positive])}.md")

    File.write!(tmp, """
    ---
    purpose: "run on start"
    triggers:
      - type: startup
    grants: []
    spend:
      cap: 1000
      window: daily
      on_breach: kill
    owner: human
    supervision: none
    ---
    body
    """)

    on_exit(fn -> File.rm(tmp) end)

    assert {:ok, %Manifest{triggers: [%{type: :startup}]}} = Manifest.load(tmp)
  end

  test "parses happy path manifest correctly" do
    tmp = Path.join(System.tmp_dir!(), "manifest_happy_#{System.unique_integer([:positive])}.md")
    File.write!(tmp, @happy_manifest)
    on_exit(fn -> File.rm(tmp) end)

    assert {:ok, %Manifest{} = m} = Manifest.load(tmp)
    assert m.purpose == "Surface content from the people-roster"
    assert m.owner == "human"
    assert m.supervision == "restart-once-and-alert"
    assert m.mounts == ["roster_trust"]

    # Triggers
    assert length(m.triggers) == 4
    assert %{type: :startup} in m.triggers
    assert %{type: :time, at: "07:00"} in m.triggers
    assert %{type: :message} in m.triggers
    assert %{type: :event, name: "approval_received"} in m.triggers

    # Grants
    assert length(m.grants) == 2
    [grant1, grant2] = m.grants
    assert %Grant{connector: "kv_append", recipients: nil, methods: ["append"]} = grant1

    assert %Grant{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]} =
             grant2

    # Spend
    assert %Spend{cap: 5, window: :daily, on_breach: :kill} = m.spend
  end

  test "raises error when grants is missing" do
    content = """
    ---
    purpose: "Test"
    owner: human
    supervision: restart-once-and-alert
    spend:
      cap: 5
      window: daily
      on_breach: kill
    ---
    """

    assert_raise RuntimeError, ~r/grants/i, fn -> load_content!(content) end
  end

  test "raises error when spend is missing" do
    content = """
    ---
    purpose: "Test"
    owner: human
    supervision: restart-once-and-alert
    grants:
      - connector: kv_append
    ---
    """

    assert_raise RuntimeError, ~r/spend/i, fn -> load_content!(content) end
  end

  test "raises error when unknown connector is used" do
    content = """
    ---
    purpose: "Test"
    owner: human
    supervision: restart-once-and-alert
    grants:
      - connector: unknown_connector_xyz
    spend:
      cap: 5
      window: daily
      on_breach: kill
    ---
    """

    assert_raise RuntimeError, ~r/unknown_connector_xyz/i, fn -> load_content!(content) end
  end

  test "raises error when spend cap is negative" do
    content = """
    ---
    purpose: "Test"
    owner: human
    supervision: restart-once-and-alert
    grants:
      - connector: kv_append
    spend:
      cap: -1
      window: daily
      on_breach: kill
    ---
    """

    assert_raise RuntimeError, ~r/cap/i, fn -> load_content!(content) end
  end

  test "raises error when spend window is invalid" do
    content = """
    ---
    purpose: "Test"
    owner: human
    supervision: restart-once-and-alert
    grants:
      - connector: kv_append
    spend:
      cap: 5
      window: hourly
      on_breach: kill
    ---
    """

    assert_raise RuntimeError, ~r/window/i, fn -> load_content!(content) end
  end

  test "raises error when spend on_breach is invalid" do
    content = """
    ---
    purpose: "Test"
    owner: human
    supervision: restart-once-and-alert
    grants:
      - connector: kv_append
    spend:
      cap: 5
      window: daily
      on_breach: alert
    ---
    """

    assert_raise RuntimeError, ~r/on_breach/i, fn -> load_content!(content) end
  end

  defp load_content!(content) do
    tmp = Path.join(System.tmp_dir!(), "manifest_test_#{System.unique_integer([:positive])}.md")
    File.write!(tmp, content)

    try do
      Manifest.load(tmp)
    after
      File.rm(tmp)
    end
  end
end
