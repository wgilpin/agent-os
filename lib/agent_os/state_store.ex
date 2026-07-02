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
    # Extract file path and default initial state
    path = Keyword.fetch!(opts, :path)
    initial = Keyword.get(opts, :initial, %{})

    if path == ":memory:" or String.ends_with?(path, ".db") do
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

      {:ok, %{backend: :sqlite, conn: conn, path: path}}
    else
      # Attempt to load state from disk.
      data =
        if File.exists?(path) do
          # Read raw binary and deserialize using Erlang term deserializer.
          # :erlang.binary_to_term/1 converts a binary back to an Elixir map/term.
          path |> File.read!() |> :erlang.binary_to_term()
        else
          # If the file does not exist, use the initial state.
          initial
        end

      # Return {:ok, initial_state}
      {:ok, %{backend: :term_file, path: path, data: data}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, %{backend: :sqlite} = state) do
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
  def handle_call(:snapshot, _from, state) do
    # Return `{:reply, response, new_state}` where response is the state data copy.
    {:reply, state.data, state}
  end

  @impl true
  def handle_call({:query, query_params}, _from, %{backend: :sqlite} = state) do
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
  def handle_call({:apply, {:append, _list_key, record}}, _from, %{backend: :sqlite} = state) do
    do_sqlite_append(state, record)
  end

  @impl true
  def handle_call({:apply, {:append, record}}, _from, %{backend: :sqlite} = state) do
    do_sqlite_append(state, record)
  end

  @impl true
  def handle_call({:apply, {:append, list_key, item}}, _from, state) do
    # Map.update/4 updates the key in the map. If the key is not present, it inserts [item].
    # Otherwise, it appends the item to the existing list (`list ++ [item]`).
    new_data = Map.update(state.data, list_key, [item], fn list -> list ++ [item] end)

    # Persist the updated state to the term-file.
    :ok = persist(state.path, new_data)

    # Reply `:ok` to the caller, and update the GenServer's internal state.
    {:reply, :ok, %{state | data: new_data}}
  end

  @impl true
  def handle_call({:apply, {:put, key, value}}, _from, state) do
    # Map.put/3 adds or replaces the key with the value.
    new_data = Map.put(state.data, key, value)

    # Persist state.
    :ok = persist(state.path, new_data)

    # Reply and update state.
    {:reply, :ok, %{state | data: new_data}}
  end

  @impl true
  def handle_call({:apply, {:delete_in, path}}, _from, state) when is_list(path) do
    # pop_in/2 removes the element at the nested path and returns a tuple with the element and the new map.
    {_popped, new_data} = pop_in(state.data, path)

    # Persist state.
    :ok = persist(state.path, new_data)

    # Reply and update state.
    {:reply, :ok, %{state | data: new_data}}
  end

  @impl true
  def handle_call({:apply, _bad}, _from, state) do
    # Fallback to handle malformed action calls.
    {:reply, {:error, :bad_action}, state}
  end

  @impl true
  def terminate(_reason, %{backend: :sqlite, conn: conn}) do
    Exqlite.Sqlite3.close(conn)
    :ok
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # Helpers

  defp do_sqlite_append(state, record) do
    json_data = Jason.encode!(record)

    case Exqlite.Sqlite3.prepare(state.conn, "INSERT INTO records (data) VALUES (?);") do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, [json_data])
        :done = Exqlite.Sqlite3.step(state.conn, stmt)
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

  # Atomic write: serialize to a tmp file, then rename into place.
  # This guarantees that if the node crashes mid-write, the existing file is untouched.
  defp persist(path, data) do
    # Ensure directory structure exists.
    path |> Path.dirname() |> File.mkdir_p!()

    # Append ".tmp" to the path.
    tmp = path <> ".tmp"

    # Serialize the data using Erlang External Term Format, and write it to the tmp file.
    File.write!(tmp, :erlang.term_to_binary(data))

    # Atomically rename the tmp file to the target path.
    File.rename!(tmp, path)

    # Return :ok.
    :ok
  end
end
