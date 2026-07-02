defmodule AgentOS.StateStore do
  @moduledoc """
  Single-writer GenServer that owns persistent state for a named mount (DEC-single-writer-per-store).

  The substrate owns all mutable state. This process is the SOLE mutation path: every
  write is a serialized message to its mailbox, so there are no locks and no lost-update
  races. An agent run never touches the live store — it receives a snapshot copy (by
  BEAM message-passing semantics) and all effects funnel through `apply_action/2`.

  State is persisted to a term-file with an atomic write (tmp + rename) so a crash
  mid-write cannot leave a torn file.
  """

  use GenServer

  # Public API

  @doc """
  Returns a standard `:via` tuple for registering or looking up a store by name via Registry.
  """
  def via_tuple(name) do
    {:via, Registry, {AgentOS.StateStoreRegistry, name}}
  end

  @doc """
  Custom child specification for dynamic registration.
  This allows starting multiple instances of this GenServer with different names/paths
  in the supervisor tree.
  """
  def child_spec(opts) do
    # Fetch the name option from opts, raising an exception if not provided.
    name = Keyword.fetch!(opts, :name)

    %{
      # Ensure each instance has a unique ID in the supervisor tree.
      id: name,
      # MFA tuple specifying how to start the process.
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Starts the GenServer for the given mount name.

  ## Options:
    - `:name` - Registration name (string or atom, e.g. `"roster_trust"`).
    - `:path` - Binary path to save the term-file.
    - `:initial` - Fallback map if the term-file does not exist.
  """
  def start_link(opts) do
    # Fetch the name key.
    name = Keyword.fetch!(opts, :name)
    # Start and link the GenServer. Registers the server under the custom registry name.
    GenServer.start_link(__MODULE__, opts, name: via_tuple(name))
  end

  @doc "Returns a COPY of the current state map of the given store name."
  def snapshot(name) do
    # GenServer.call/2 sends a synchronous message to the GenServer, blocking until it replies.
    # Because of BEAM's share-nothing process architecture, the state returned is copied,
    # ensuring no shared mutable state issues.
    GenServer.call(via_tuple(name), :snapshot)
  end

  @doc """
  Applies a mutation action to the given store name.
  Supported operations:
    - `{:append, list_key, item}`: Appends `item` to the list at `list_key` in the state map.
    - `{:put, key, value}`: Sets `key` to `value` in the state map.
    - `{:delete_in, path}`: Deletes a nested key at the given keypath `path` (list).
  """
  def apply_action(name, action) do
    # Send a synchronous call to perform the action.
    GenServer.call(via_tuple(name), {:apply, action})
  end

  @doc """
  Queries records matching field predicates from the given record store.
  """
  @spec query(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def query(name, query_params) when is_map(query_params) do
    GenServer.call(via_tuple(name), {:query, query_params})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    # Extract file path and operational mode
    path = Keyword.fetch!(opts, :path)

    mode =
      cond do
        Keyword.has_key?(opts, :mode) -> Keyword.get(opts, :mode)
        is_map(Keyword.get(opts, :initial)) -> :map
        true -> :record
      end

    default_initial = if mode == :map, do: %{}, else: []
    initial = Keyword.get(opts, :initial, default_initial)

    # Ensure parent directory exists for file-based DBs
    if path != ":memory:" do
      path |> Path.dirname() |> File.mkdir_p!()
    end

    # Open SQLite connection
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    # Enable WAL mode for crash-durability and concurrency (if not in-memory)
    if path != ":memory:" do
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "PRAGMA journal_mode=WAL;")
      _ = Exqlite.Sqlite3.step(conn, statement)
      :ok = Exqlite.Sqlite3.release(conn, statement)
    end

    case mode do
      :record ->
        # Create table records
        create_sql = """
        CREATE TABLE IF NOT EXISTS records (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          data TEXT NOT NULL,
          created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );
        """

        {:ok, statement} = Exqlite.Sqlite3.prepare(conn, create_sql)
        _ = Exqlite.Sqlite3.step(conn, statement)
        :ok = Exqlite.Sqlite3.release(conn, statement)

      :map ->
        # Create table map_store
        create_sql = """
        CREATE TABLE IF NOT EXISTS map_store (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """

        {:ok, statement} = Exqlite.Sqlite3.prepare(conn, create_sql)
        _ = Exqlite.Sqlite3.step(conn, statement)
        :ok = Exqlite.Sqlite3.release(conn, statement)

        # Seed initial state if table is empty
        {:ok, count_stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT COUNT(*) FROM map_store;")
        {:row, [count]} = Exqlite.Sqlite3.step(conn, count_stmt)
        :ok = Exqlite.Sqlite3.release(conn, count_stmt)

        if count == 0 and is_map(initial) do
          Enum.each(initial, fn {k, v} ->
            json_val = Jason.encode!(encode_term(v))

            {:ok, insert_stmt} =
              Exqlite.Sqlite3.prepare(conn, "INSERT INTO map_store (key, value) VALUES (?, ?);")

            :ok = Exqlite.Sqlite3.bind(insert_stmt, [db_key(k), json_val])
            _ = Exqlite.Sqlite3.step(conn, insert_stmt)
            :ok = Exqlite.Sqlite3.release(conn, insert_stmt)
          end)
        end
    end

    {:ok, %{conn: conn, path: path, mode: mode}}
  end

  @impl true
  def handle_call(:snapshot, _from, %{mode: :record} = state) do
    case Exqlite.Sqlite3.prepare(
           state.conn,
           "SELECT data FROM records ORDER BY id ASC;"
         ) do
      {:ok, stmt} ->
        {:ok, rows} = fetch_all(state.conn, stmt)
        :ok = Exqlite.Sqlite3.release(state.conn, stmt)
        records = Enum.map(rows, fn [data_str] -> Jason.decode!(data_str) end)
        {:reply, records, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, %{mode: :map} = state) do
    case Exqlite.Sqlite3.prepare(state.conn, "SELECT key, value FROM map_store;") do
      {:ok, stmt} ->
        {:ok, rows} = fetch_all(state.conn, stmt)
        :ok = Exqlite.Sqlite3.release(state.conn, stmt)

        map =
          Enum.reduce(rows, %{}, fn [key, value_str], acc ->
            Map.put(acc, restore_key(key), decode_term(Jason.decode!(value_str)))
          end)

        {:reply, map, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:query, query_params}, _from, %{mode: :record} = state) do
    case build_and_execute_query(state.conn, query_params) do
      {:ok, records} -> {:reply, {:ok, records}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:query, _query_params}, _from, state) do
    {:reply, {:error, :unsupported_backend}, state}
  end

  @impl true
  def handle_call({:apply, {:append, _list_key, record}}, _from, %{mode: :record} = state) do
    do_sqlite_append(state, record)
  end

  @impl true
  def handle_call({:apply, {:append, record}}, _from, %{mode: :record} = state) do
    do_sqlite_append(state, record)
  end

  @impl true
  def handle_call({:apply, {:append, list_key, item}}, _from, %{mode: :map} = state) do
    list_key_str = db_key(list_key)

    case Exqlite.Sqlite3.prepare(state.conn, "SELECT value FROM map_store WHERE key = ?;") do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [list_key_str])
        row_result = Exqlite.Sqlite3.step(state.conn, stmt)
        :ok = Exqlite.Sqlite3.release(state.conn, stmt)

        existing_list =
          case row_result do
            {:row, [value_str]} ->
              case decode_term(Jason.decode!(value_str)) do
                list when is_list(list) -> list
                _ -> []
              end

            _ ->
              []
          end

        new_list = existing_list ++ [item]
        json_val = Jason.encode!(encode_term(new_list))

        case Exqlite.Sqlite3.prepare(
               state.conn,
               "INSERT INTO map_store (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
             ) do
          {:ok, insert_stmt} ->
            :ok = Exqlite.Sqlite3.bind(insert_stmt, [list_key_str, json_val])
            _ = Exqlite.Sqlite3.step(state.conn, insert_stmt)
            :ok = Exqlite.Sqlite3.release(state.conn, insert_stmt)
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:apply, {:put, key, value}}, _from, %{mode: :map} = state) do
    key_str = db_key(key)
    json_val = Jason.encode!(encode_term(value))

    case Exqlite.Sqlite3.prepare(
           state.conn,
           "INSERT INTO map_store (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
         ) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [key_str, json_val])
        _ = Exqlite.Sqlite3.step(state.conn, stmt)
        :ok = Exqlite.Sqlite3.release(state.conn, stmt)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:apply, {:delete_in, path}}, _from, %{mode: :map} = state)
      when is_list(path) do
    case path do
      [single_key] ->
        key_str = db_key(single_key)

        case Exqlite.Sqlite3.prepare(state.conn, "DELETE FROM map_store WHERE key = ?;") do
          {:ok, stmt} ->
            :ok = Exqlite.Sqlite3.bind(stmt, [key_str])
            _ = Exqlite.Sqlite3.step(state.conn, stmt)
            :ok = Exqlite.Sqlite3.release(state.conn, stmt)
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      [top_key | rest] ->
        top_key_str = db_key(top_key)

        case Exqlite.Sqlite3.prepare(state.conn, "SELECT value FROM map_store WHERE key = ?;") do
          {:ok, stmt} ->
            :ok = Exqlite.Sqlite3.bind(stmt, [top_key_str])
            row_result = Exqlite.Sqlite3.step(state.conn, stmt)
            :ok = Exqlite.Sqlite3.release(state.conn, stmt)

            case row_result do
              {:row, [value_str]} ->
                map = decode_term(Jason.decode!(value_str))

                if is_map(map) do
                  {_popped, updated_map} = pop_in(map, rest)
                  json_val = Jason.encode!(encode_term(updated_map))

                  case Exqlite.Sqlite3.prepare(
                         state.conn,
                         "INSERT INTO map_store (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
                       ) do
                    {:ok, insert_stmt} ->
                      :ok = Exqlite.Sqlite3.bind(insert_stmt, [top_key_str, json_val])
                      _ = Exqlite.Sqlite3.step(state.conn, insert_stmt)
                      :ok = Exqlite.Sqlite3.release(state.conn, insert_stmt)
                      {:reply, :ok, state}

                    {:error, reason} ->
                      {:reply, {:error, reason}, state}
                  end
                else
                  {:reply, :ok, state}
                end

              _ ->
                {:reply, :ok, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:apply, _bad}, _from, state) do
    # Fallback to handle malformed action calls.
    {:reply, {:error, :bad_action}, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) do
    Exqlite.Sqlite3.close(conn)
    :ok
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # Helpers

  defp db_key(key) do
    cond do
      is_atom(key) -> "a:#{key}"
      is_binary(key) -> "s:#{key}"
      true -> to_string(key)
    end
  end

  defp restore_key(db_key_str) do
    case db_key_str do
      "a:" <> atom_str ->
        try do
          String.to_existing_atom(atom_str)
        rescue
          _ -> String.to_atom(atom_str)
        end

      "s:" <> string_str ->
        string_str

      _ ->
        db_key_str
    end
  end

  defp encode_term(val) do
    cond do
      is_struct(val) ->
        map = Map.from_struct(val)
        encoded_map = encode_map(map)
        Map.put(encoded_map, "__struct__", to_string(val.__struct__))

      is_tuple(val) ->
        %{"__tuple__" => true, "elements" => Enum.map(Tuple.to_list(val), &encode_term/1)}

      is_map(val) ->
        encode_map(val)

      is_list(val) ->
        Enum.map(val, &encode_term/1)

      is_atom(val) and not is_nil(val) and not is_boolean(val) ->
        %{"__atom__" => true, "value" => to_string(val)}

      true ->
        val
    end
  end

  defp encode_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      encoded_key =
        cond do
          is_atom(k) -> "a:#{k}"
          is_binary(k) -> "s:#{k}"
          true -> to_string(k)
        end

      Map.put(acc, encoded_key, encode_term(v))
    end)
  end

  defp decode_term(val) do
    cond do
      is_map(val) ->
        cond do
          Map.get(val, "__atom__") == true ->
            atom_str = Map.get(val, "value")

            try do
              String.to_existing_atom(atom_str)
            rescue
              _ -> String.to_atom(atom_str)
            end

          Map.get(val, "__tuple__") == true ->
            list = Enum.map(Map.get(val, "elements") || [], &decode_term/1)
            List.to_tuple(list)

          struct_str = Map.get(val, "__struct__") ->
            struct_module = String.to_existing_atom(struct_str)
            decoded_map = decode_map(Map.delete(val, "__struct__"))
            struct!(struct_module, decoded_map)

          true ->
            decode_map(val)
        end

      is_list(val) ->
        Enum.map(val, &decode_term/1)

      true ->
        val
    end
  end

  defp decode_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      decoded_key =
        case k do
          "a:" <> atom_str ->
            try do
              String.to_existing_atom(atom_str)
            rescue
              _ -> String.to_atom(atom_str)
            end

          "s:" <> string_str ->
            string_str

          _ ->
            k
        end

      Map.put(acc, decoded_key, decode_term(v))
    end)
  end

  defp do_sqlite_append(state, record) do
    json_data = Jason.encode!(record)

    case Exqlite.Sqlite3.prepare(state.conn, "INSERT INTO records (data) VALUES (?);") do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [json_data])
        _ = Exqlite.Sqlite3.step(state.conn, stmt)
        :ok = Exqlite.Sqlite3.release(state.conn, stmt)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp fetch_all(conn, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all(conn, stmt, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
    end
  end

  defp build_and_execute_query(conn, params) do
    predicates = Map.get(params, "predicates") || Map.get(params, :predicates) || []
    limit = Map.get(params, "limit") || Map.get(params, :limit)
    order_by = Map.get(params, "order_by") || Map.get(params, :order_by)
    order = Map.get(params, "order") || Map.get(params, :order) || "asc"

    # Build WHERE clause
    {where_clauses, bindings} =
      Enum.reduce(predicates, {[], []}, fn pred, {clauses, binds} ->
        {field, op, val} =
          case pred do
            %{} = m ->
              f = Map.get(m, "field") || Map.get(m, :field)
              o = Map.get(m, "operator") || Map.get(m, :operator)
              v = Map.get(m, "value") || Map.get(m, :value)
              {f, o, v}

            {f, o, v} ->
              {f, o, v}
          end

        # Validate operator to prevent SQL injection
        valid_operators = ["=", "!=", "<", ">", "<=", ">="]

        if op in valid_operators and is_binary(field) do
          clause = "json_extract(data, '$.#{field}') #{op} ?"
          {[clause | clauses], [val | binds]}
        else
          {clauses, binds}
        end
      end)

    where_sql =
      if Enum.empty?(where_clauses) do
        ""
      else
        "WHERE " <> Enum.join(Enum.reverse(where_clauses), " AND ")
      end

    # Build ORDER BY clause
    order_sql =
      if is_binary(order_by) do
        direction =
          if to_string(order) |> String.downcase() == "desc", do: "DESC", else: "ASC"

        "ORDER BY json_extract(data, '$.#{order_by}') #{direction}"
      else
        "ORDER BY id ASC"
      end

    # Build LIMIT clause
    limit_sql =
      if is_integer(limit) do
        "LIMIT #{limit}"
      else
        ""
      end

    sql = "SELECT data FROM records #{where_sql} #{order_sql} #{limit_sql};"

    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        raw_bindings = Enum.reverse(bindings)
        :ok = Exqlite.Sqlite3.bind(stmt, raw_bindings)

        case fetch_all(conn, stmt) do
          {:ok, rows} ->
            :ok = Exqlite.Sqlite3.release(conn, stmt)
            records = Enum.map(rows, fn [data_str] -> Jason.decode!(data_str) end)
            {:ok, records}

          {:error, reason} ->
            :ok = Exqlite.Sqlite3.release(conn, stmt)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
