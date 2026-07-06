defmodule AgentOS.Connector.FileReadTest do
  use ExUnit.Case, async: true

  alias AgentOS.Connector.FileRead
  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  setup do
    test_dir = Path.join(System.tmp_dir!(), "agent_os_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)

    on_exit(fn -> File.rm_rf!(test_dir) end)

    %{test_dir: test_dir}
  end

  test "metadata returns correct capability" do
    meta = FileRead.metadata()
    assert meta.name == "file_read"
    assert meta.mutating? == false
    assert meta.requires_deploy_consent? == false
    assert meta.requires_runtime_approval? == false
    assert meta.credential == nil
    assert meta.cost == 0
  end

  test "render/1 shows path", %{test_dir: test_dir} do
    grant = %Grant{connector: "file_read", path: test_dir, handle: "doc"}
    assert FileRead.render(grant) == "[EXTERNAL] READ DOCUMENT AT #{test_dir}"
  end

  test "execute/2 successful file read", %{test_dir: test_dir} do
    file_path = Path.join(test_dir, "doc.txt")
    File.write!(file_path, "Hello from file")

    action = %ProposedAction{
      type: "file_read",
      payload: %{"handle" => "doc"},
      grant_resolved_path: file_path
    }

    assert {:ok, "Hello from file"} = FileRead.execute(action, nil)
  end

  test "execute/2 returns error on missing file", %{test_dir: test_dir} do
    file_path = Path.join(test_dir, "missing.txt")

    action = %ProposedAction{
      type: "file_read",
      payload: %{"handle" => "doc"},
      grant_resolved_path: file_path
    }

    assert {:error, :enoent} = FileRead.execute(action, nil)
  end

  test "execute/2 returns error when grant_resolved_path is nil" do
    action = %ProposedAction{
      type: "file_read",
      payload: %{"handle" => "doc"},
      grant_resolved_path: nil
    }

    assert {:error, :missing_path} = FileRead.execute(action, nil)
  end
end
