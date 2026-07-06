defmodule AgentOS.Connector.FileWriteTest do
  use ExUnit.Case, async: true

  alias AgentOS.Connector.FileWrite
  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  setup do
    test_dir = Path.join(System.tmp_dir!(), "agent_os_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)

    on_exit(fn -> File.rm_rf!(test_dir) end)

    %{test_dir: test_dir}
  end

  test "metadata returns correct capability" do
    meta = FileWrite.metadata()
    assert meta.name == "file_write"
    assert meta.mutating? == true
    assert meta.requires_deploy_consent? == true
    assert meta.requires_runtime_approval? == false
    assert meta.credential == nil
    assert meta.cost == 0
  end

  test "render/1 shows path", %{test_dir: test_dir} do
    grant = %Grant{connector: "file_write", path: test_dir, handle: "doc"}
    assert FileWrite.render(grant) == "[EXTERNAL] WRITE DOCUMENT AT #{test_dir}"
  end

  test "execute/2 successful atomic file write", %{test_dir: test_dir} do
    file_path = Path.join(test_dir, "doc.txt")

    action = %ProposedAction{
      type: "file_write",
      payload: %{"handle" => "doc", "content" => "New content!"},
      grant_resolved_path: file_path
    }

    assert :ok = FileWrite.execute(action, nil)
    assert File.read!(file_path) == "New content!"
  end

  test "execute/2 successful atomic write over existing file", %{test_dir: test_dir} do
    file_path = Path.join(test_dir, "doc.txt")
    File.write!(file_path, "Old content")

    action = %ProposedAction{
      type: "file_write",
      payload: %{"handle" => "doc", "content" => "Updated content"},
      grant_resolved_path: file_path
    }

    assert :ok = FileWrite.execute(action, nil)
    assert File.read!(file_path) == "Updated content"
  end

  test "execute/2 returns error on missing payload content", %{test_dir: test_dir} do
    file_path = Path.join(test_dir, "doc.txt")

    action = %ProposedAction{
      type: "file_write",
      payload: %{"handle" => "doc"},
      grant_resolved_path: file_path
    }

    assert {:error, :missing_content} = FileWrite.execute(action, nil)
  end

  test "execute/2 loud failure on I/O error", %{test_dir: test_dir} do
    action = %ProposedAction{
      type: "file_write",
      payload: %{"handle" => "doc", "content" => "test"},
      grant_resolved_path: test_dir
    }

    assert {:error, _reason} = FileWrite.execute(action, nil)
  end

  test "execute/2 returns error when grant_resolved_path is nil" do
    action = %ProposedAction{
      type: "file_write",
      payload: %{"handle" => "doc", "content" => "test"},
      grant_resolved_path: nil
    }

    assert {:error, :missing_path} = FileWrite.execute(action, nil)
  end
end
