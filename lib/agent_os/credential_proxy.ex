defmodule AgentOS.CredentialProxy do
  @moduledoc """
  AgentOS.CredentialProxy is a single-writer GenServer holding secrets keyed by registry
  credential id in memory (no persistence).

  Principle XI Invariant:
  No LLM-running component (the agent workload) holds mutating credentials. Injection
  happens only at action time, only after gate approval, and only at the effector chokepoint.
  """

  use GenServer
  require Logger

  # Client API

  @doc """
  Starts the CredentialProxy GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Executes a function with the resolved secret for `credential_id`.
  The secret is never returned to the caller, never logged, and never persisted.
  The execution of the closure happens in the caller process, protecting the GenServer from crashes.
  """
  @spec with_credential(credential_id :: atom(), fun :: (String.t() -> result)) ::
          result | {:error, {:unknown_credential, atom()}}
        when result: var
  def with_credential(credential_id, fun) when is_atom(credential_id) and is_function(fun, 1) do
    case GenServer.call(__MODULE__, {:get_credential, credential_id}) do
      {:ok, secret} ->
        # Apply the closure in the caller process
        fun.(secret)

      {:error, {:unknown_credential, id}} ->
        Logger.error("Failed to resolve credential ID: :#{id} (unknown credential ID)")
        {:error, {:unknown_credential, id}}
    end
  end

  # Server Callbacks

  @impl true
  def init(:ok) do
    # Load credentials map dynamically from environment/config at runtime
    credentials = AgentOS.CredentialSource.resolve_credentials()
    {:ok, credentials}
  end

  @impl true
  def handle_call({:get_credential, credential_id}, _from, state) do
    case Map.fetch(state, credential_id) do
      {:ok, secret} when is_binary(secret) ->
        {:reply, {:ok, secret}, state}

      _ ->
        # Check dynamic mapping for admitted plugins
        mapping_value =
          Enum.find_value(AgentOS.Connector.admitted_plugins_map(), nil, fn {_mod, config} ->
            mappings = Map.get(config, :credential_mappings, %{})

            case Map.fetch(mappings, credential_id) do
              {:ok, source_env_atom} ->
                env_var_name = source_env_atom |> Atom.to_string() |> String.upcase()

                System.get_env(env_var_name) ||
                  Map.get(Application.get_env(:agent_os, :credentials, %{}), source_env_atom)

              _ ->
                nil
            end
          end)

        if mapping_value && String.trim(mapping_value) != "" do
          {:reply, {:ok, String.trim(mapping_value)}, state}
        else
          {:reply, {:error, {:unknown_credential, credential_id}}, state}
        end
    end
  end
end
