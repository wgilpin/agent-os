defmodule AgentOS.CredentialSource do
  @moduledoc """
  Consolidated loader and resolver for application credentials.
  Loads environment variables from `.env` files dynamically, validates presence,
  and handles fallback configuration mapping.
  """

  @doc """
  Resolves model API credentials from the runtime system environment,
  falling back to Application configuration environment settings if necessary.
  Ensures blank or whitespace-only keys are excluded.
  """
  @spec resolve_credentials() :: %{optional(atom()) => String.t()}
  def resolve_credentials do
    # Load .env file at startup to populate System environment. Gated by
    # :load_dotenv (false in the test env) rather than :autostart alone: tests
    # legitimately flip :autostart for the UDS broker harness, and that must not
    # leak real secrets into the test VM's System env (Constitution IV).
    if Application.get_env(:agent_os, :autostart, true) and
         Application.get_env(:agent_os, :load_dotenv, true) do
      load_env_file()
    end

    # Fall back to application configuration environment (mainly for tests)
    config = Application.get_env(:agent_os, :credentials, %{})

    # Collect all credentials declared by auto-discovered connectors, plus :model_key
    connector_credential_ids =
      try do
        AgentOS.Connector.registry()
        |> Map.values()
        |> Enum.map(&Map.get(&1, :credential))
        |> Enum.filter(&(not is_nil(&1)))
      rescue
        _ -> []
      end

    all_credential_ids = Enum.uniq([:model_key | Map.keys(config) ++ connector_credential_ids])

    # Resolve each dynamically
    Enum.reduce(all_credential_ids, %{}, fn credential_id, acc ->
      env_var_name = credential_id |> Atom.to_string() |> String.upcase()
      value = System.get_env(env_var_name) || Map.get(config, credential_id)

      if non_blank?(value) do
        Map.put(acc, credential_id, String.trim(value))
      else
        acc
      end
    end)
  end

  # Helper to parse a local .env file (if present) and populate System environment variables
  defp load_env_file do
    if File.exists?(".env") do
      # Stream the .env file line by line to keep memory footprint small
      File.stream!(".env")
      |> Enum.each(fn line ->
        line = String.trim(line)

        # Ignore empty lines and comments
        if line != "" and not String.starts_with?(line, "#") do
          # Strip optional export command prefix
          line =
            if String.starts_with?(line, "export "),
              do: String.slice(line, 7..-1//1),
              else: line

          case String.split(line, "=", parts: 2) do
            [key, val] ->
              key = String.trim(key)
              # Strip optional surrounding single or double quotes
              val = val |> String.trim() |> String.trim("\"") |> String.trim("'")
              System.put_env(key, val)

            _ ->
              :ok
          end
        end
      end)
    end
  end

  # Helper checking that a value is a non-empty, non-whitespace string
  defp non_blank?(val) when is_binary(val) do
    String.trim(val) != ""
  end

  defp non_blank?(_val), do: false
end
