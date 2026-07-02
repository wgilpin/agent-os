defmodule AgentOS.Connector do
  @moduledoc """
  Defines the connector capability behaviour and auto-discovered registry.
  """

  @type capability :: %{
          name: String.t(),
          mutating?: boolean(),
          requires_deploy_consent?: boolean(),
          requires_runtime_approval?: boolean(),
          credential: atom() | nil,
          # cost in integer micro-dollars (1e-6 USD); 0 means free
          cost: integer(),
          tool_declaration: map() | nil
        }

  # Callbacks for dynamic connector capabilities
  @callback metadata() :: capability()
  @callback scope(boundaries :: map()) :: AgentOS.Manifest.Grant.t()
  @callback execute(action :: AgentOS.ProposedAction.t(), secret :: String.t() | nil) ::
              :ok | {:ok, term()} | {:error, term()}
  @callback render(grant :: AgentOS.Manifest.Grant.t()) :: String.t()
  @callback execute_tool(arguments :: map(), secret :: String.t() | nil) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks [execute_tool: 2]

  @doc """
  Returns the complete connector registry map.
  """
  @spec registry() :: %{String.t() => capability()}
  def registry do
    case Application.get_env(:agent_os, :connector_registry) do
      nil -> discover_and_build_registry()
      override -> override
    end
  end

  @doc """
  Looks up a connector by name in the registry.
  Returns `{:ok, capability}` or `{:error, :unknown_connector}`.
  """
  @spec get(String.t()) :: {:ok, capability()} | {:error, :unknown_connector}
  def get(name) when is_binary(name) do
    case Map.fetch(registry(), name) do
      {:ok, cap} -> {:ok, cap}
      :error -> {:error, :unknown_connector}
    end
  end

  @doc """
  Returns the list of all registered connector names.
  """
  @spec registered_names() :: [String.t()]
  def registered_names do
    Map.keys(registry())
  end

  @doc """
  Retrieves the backing module implementing the capability.
  Returns `{:ok, module}` or `{:error, :unknown_connector}`.
  """
  @spec get_module(String.t()) :: {:ok, module()} | {:error, :unknown_connector}
  def get_module(name) when is_binary(name) do
    load_plugins()

    result =
      Enum.find_value(all_modules(), fn mod ->
        case Code.ensure_loaded(mod) do
          {:module, loaded_mod} ->
            if admitted?(loaded_mod) do
              attrs = loaded_mod.module_info(:attributes)

              behaviours =
                Keyword.get(attrs, :behaviour, []) ++ Keyword.get(attrs, :behavior, [])

              if AgentOS.Connector in behaviours do
                meta = loaded_mod.metadata()

                if meta.name == name do
                  {:ok, loaded_mod}
                else
                  nil
                end
              else
                nil
              end
            else
              nil
            end

          _ ->
            nil
        end
      end)

    result || {:error, :unknown_connector}
  end

  @first_party_modules [
    AgentOS.Connector.KvAppend,
    AgentOS.Connector.ExternalSend,
    AgentOS.Connector.GmailRead,
    AgentOS.Connector.GmailDraft,
    AgentOS.Connector.WebSearch,
    AgentOS.Connector.StoreAppend,
    AgentOS.Connector.StoreFind,
    AgentOS.Connector.TestFixture,
    AgentOS.Connector.TimeoutFixture,
    AgentOS.Connector.CrashFixture
  ]

  @doc """
  Admits a plugin module and registers its credential mappings.
  """
  @spec admit(module(), map()) :: :ok | {:error, term()}
  def admit(module, credential_mappings \\ %{})
      when is_atom(module) and is_map(credential_mappings) do
    case Code.ensure_loaded(module) do
      {:module, loaded_mod} ->
        attrs = loaded_mod.module_info(:attributes)
        behaviours = Keyword.get(attrs, :behaviour, []) ++ Keyword.get(attrs, :behavior, [])

        if AgentOS.Connector in behaviours do
          AgentOS.StateStore.apply_action(
            "admitted_plugins",
            {:put, module, %{credential_mappings: credential_mappings}}
          )

          :ok
        else
          {:error, :not_a_connector}
        end

      _ ->
        {:error, :module_not_found}
    end
  end

  @doc """
  Checks if a plugin module is admitted (either first-party or explicitly admitted).
  """
  @spec admitted?(module()) :: boolean()
  def admitted?(module) when is_atom(module) do
    if module in @first_party_modules do
      true
    else
      Map.has_key?(admitted_plugins_map(), module)
    end
  end

  @doc """
  Helper to return the map of all admitted third-party plugins.
  """
  @spec admitted_plugins_map() :: map()
  def admitted_plugins_map do
    try do
      AgentOS.StateStore.snapshot("admitted_plugins")
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end

  @doc """
  Scans the plugins directory and dynamically loads precompiled `.beam` files.
  """
  @spec load_plugins() :: :ok
  def load_plugins do
    plugins_dir = Application.get_env(:agent_os, :plugins_path, "data/plugins")

    if File.dir?(plugins_dir) do
      plugins_dir
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.each(fn path ->
        filename = Path.basename(path, ".beam")
        module_atom = String.to_atom(filename)

        case File.read(path) do
          {:ok, binary} ->
            case :code.load_binary(module_atom, to_charlist(path), binary) do
              {:module, _mod} ->
                :ok

              {:error, reason} ->
                require Logger

                Logger.error(
                  "Failed to dynamically load plugin BEAM file from #{path}: #{inspect(reason)}"
                )
            end

          {:error, reason} ->
            require Logger
            Logger.error("Failed to read plugin file #{path}: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  # Helper to scan modules at boot and compile registry map from metadata
  defp discover_and_build_registry do
    load_plugins()

    all_modules()
    |> Enum.reduce(%{}, fn mod, acc ->
      case Code.ensure_loaded(mod) do
        {:module, loaded_mod} ->
          if admitted?(loaded_mod) do
            attrs = loaded_mod.module_info(:attributes)

            behaviours =
              Keyword.get(attrs, :behaviour, []) ++ Keyword.get(attrs, :behavior, [])

            if AgentOS.Connector in behaviours do
              meta = loaded_mod.metadata()
              meta_with_defaults = Map.put_new(meta, :tool_declaration, nil)
              Map.put(acc, meta_with_defaults.name, meta_with_defaults)
            else
              acc
            end
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  # Returns all modules in the application spec, plus dynamically loaded ones starting with Elixir.AgentOS.Connector
  defp all_modules do
    app_modules =
      case Application.spec(:agent_os, :modules) do
        nil -> []
        list -> list
      end

    loaded_modules =
      for {mod, _} <- :code.all_loaded(),
          String.starts_with?(to_string(mod), "Elixir.AgentOS.Connector.") do
        mod
      end

    Enum.uniq(app_modules ++ loaded_modules)
  end

  @doc """
  Executes the mock sink for external_send.
  Sends the action and injected credential to the test-registered process if configured.
  """
  @spec external_send_sink(any(), String.t()) :: :ok
  def external_send_sink(action, secret) when is_binary(secret) do
    case Application.get_env(:agent_os, :external_send_sink_pid) do
      pid when is_pid(pid) ->
        send(pid, {:external_send, %{action: action, credential: secret}})
        :ok

      _ ->
        :ok
    end
  end
end
