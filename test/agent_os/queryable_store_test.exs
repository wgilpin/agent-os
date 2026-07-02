defmodule AgentOS.QueryableStoreTest do
  use ExUnit.Case, async: false

  alias AgentOS.StateStore

  setup do
    AgentOS.TestHelper.start_mounts!()

    uniq = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "queryable_test_#{uniq}.db")

    # Start supervised StateStore
    start_supervised!({StateStore, name: "queryable_db", path: db_path})

    on_exit(fn ->
      # Clean up test database file
      File.rm(db_path)
      # Also clean up WAL helper files if present
      File.rm(db_path <> "-wal")
      File.rm(db_path <> "-shm")
    end)

    {:ok, db_path: db_path}
  end

  test "SQLite database initialization and WAL settings", _context do
    # Verify the state store is running with a sqlite backend
    state = GenServer.call(StateStore.via_tuple("queryable_db"), :snapshot)
    # SQLite backend returns lists on snapshot
    assert is_list(state)

    # Verify WAL journal mode is active
    conn = :sys.get_state(StateStore.via_tuple("queryable_db")).conn
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "PRAGMA journal_mode;")
    assert {:row, [journal_mode]} = Exqlite.Sqlite3.step(conn, stmt)
    # in WAL mode on disk
    assert journal_mode in ["wal", "memory"]
    :ok = Exqlite.Sqlite3.release(conn, stmt)
  end

  test "US1 & US2: append records and query via predicates" do
    # 1. Append multiple opaque records
    assert :ok =
             StateStore.apply_action(
               "queryable_db",
               {:append, %{"name" => "alice", "age" => 25, "role" => "dev"}}
             )

    assert :ok =
             StateStore.apply_action(
               "queryable_db",
               {:append, %{"name" => "bob", "age" => 30, "role" => "pm"}}
             )

    assert :ok =
             StateStore.apply_action(
               "queryable_db",
               {:append, %{"name" => "charlie", "age" => 35, "role" => "dev"}}
             )

    # 2. Query equality predicate (role = dev)
    assert {:ok, dev_records} =
             StateStore.query("queryable_db", %{
               predicates: [%{field: "role", operator: "=", value: "dev"}]
             })

    assert length(dev_records) == 2
    names = Enum.map(dev_records, & &1["name"]) |> Enum.sort()
    assert names == ["alice", "charlie"]

    # 3. Query comparison predicate (age > 28)
    assert {:ok, older_records} =
             StateStore.query("queryable_db", %{
               predicates: [%{field: "age", operator: ">", value: 28}]
             })

    assert length(older_records) == 2
    names = Enum.map(older_records, & &1["name"]) |> Enum.sort()
    assert names == ["bob", "charlie"]

    # 4. Limit and ordering (order_by age DESC, limit 2)
    assert {:ok, limited_records} =
             StateStore.query("queryable_db", %{
               order_by: "age",
               order: "desc",
               limit: 2
             })

    assert [%{"name" => "charlie"}, %{"name" => "bob"}] = limited_records
  end

  test "US4: committed writes survive GenServer crash/restart", _context do
    # 1. Append record
    assert :ok = StateStore.apply_action("queryable_db", {:append, %{"name" => "dave"}})

    # 2. Simulate crash by stopping the process
    pid = GenServer.whereis(StateStore.via_tuple("queryable_db"))
    assert is_pid(pid)

    # Terminate process synchronously
    GenServer.stop(pid)
    refute Process.alive?(pid)
    Process.sleep(100)

    # 3. Assert new GenServer PID is alive and registry has updated
    new_pid = GenServer.whereis(StateStore.via_tuple("queryable_db"))
    assert is_pid(new_pid)
    assert new_pid != pid

    # 4. Verify records are intact and queryable
    assert {:ok, records} = StateStore.query("queryable_db", %{})
    assert [%{"name" => "dave"}] = records
  end

  test "US3: Policy-Bound Agent-Invisible Namespaces", context do
    alias AgentOS.Gate
    alias AgentOS.Effector
    alias AgentOS.Manifest
    alias AgentOS.Manifest.Grant

    # 1. Setup a mock manifest with mapping: feedback -> agent_feedback_prod_v2
    manifest = %Manifest{
      purpose: "test",
      owner: "developer",
      supervision: [],
      spend: %{cap: 1000, window: :daily},
      grants: [
        %Grant{
          connector: "store_append",
          handle: "feedback",
          namespace: "agent_feedback_prod_v2"
        },
        %Grant{
          connector: "store_find",
          handle: "feedback",
          namespace: "agent_feedback_prod_v2"
        }
      ]
    }

    # 2. Start the StateStore for the real namespace on disk
    real_db_path = context.db_path <> "_feedback.db"
    start_supervised!({StateStore, name: "agent_feedback_prod_v2", path: real_db_path})

    # Ensure clean cleanup of the feedback DB files
    on_exit(fn ->
      File.rm(real_db_path)
      File.rm(real_db_path <> "-wal")
      File.rm(real_db_path <> "-shm")
    end)

    # 3. Agent proposes store_append action using logical handle only
    action = %{
      "type" => "store_append",
      "payload" => %{"handle" => "feedback", "record" => %{"score" => 5}}
    }

    # 4. Gate evaluate parses and returns approved grant with resolved namespace
    # also Gate.partition_batch/4 simulates the exact batch/effector boundary
    registry = %{
      "store_append" => %{
        cost: 0,
        mutating?: true,
        requires_deploy_consent?: false,
        requires_runtime_approval?: false
      },
      "store_find" => %{
        cost: 0,
        mutating?: false,
        requires_deploy_consent?: false,
        requires_runtime_approval?: false
      }
    }

    assert {[%{action: updated_action, grant: grant}], [], [], []} =
             Gate.partition_batch([action], manifest, registry, %{spent: 0})

    # Check that namespace has been resolved substrate-side
    assert updated_action.grant_resolved_namespace == "agent_feedback_prod_v2"
    assert grant.namespace == "agent_feedback_prod_v2"

    # 5. Effector applies the write
    assert :ok = Effector.act(%{action: updated_action, grant: grant})

    # 6. Read back using store_find action
    find_action = %{
      "type" => "store_find",
      "payload" => %{"handle" => "feedback"}
    }

    assert {[%{action: updated_find_action, grant: _find_grant}], [], [], []} =
             Gate.partition_batch([find_action], manifest, registry, %{spent: 0})

    assert updated_find_action.grant_resolved_namespace == "agent_feedback_prod_v2"

    # Execute read connector
    assert {:ok, records} = AgentOS.Connector.StoreFind.execute(updated_find_action, nil)
    assert records == [%{"score" => 5}]
  end
end
