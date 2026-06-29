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

  # Server callbacks

  @impl true
  def init(opts) do
    # Extract file path and default initial state
    path = Keyword.fetch!(opts, :path)
    initial = Keyword.get(opts, :initial, %{})

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
    {:ok, %{path: path, data: data}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    # Return `{:reply, response, new_state}` where response is the state data copy.
    {:reply, state.data, state}
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
