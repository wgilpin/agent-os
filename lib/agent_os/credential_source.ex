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
    # Load .env file at startup to populate System environment, except in tests
    if Application.get_env(:agent_os, :autostart, true) do
      load_env_file()
    end

    # Fall back to application configuration environment (mainly for tests)
    config = Application.get_env(:agent_os, :credentials, %{})

    model_key = System.get_env("MODEL_KEY") || Map.get(config, :model_key)
    outbound_token = System.get_env("OUTBOUND_TOKEN") || Map.get(config, :outbound_token)

    # Exclude empty or whitespace-only credentials
    credentials = %{}

    credentials =
      if non_blank?(model_key) do
        Map.put(credentials, :model_key, String.trim(model_key))
      else
        credentials
      end

    credentials =
      if non_blank?(outbound_token) do
        Map.put(credentials, :outbound_token, String.trim(outbound_token))
      else
        credentials
      end

    credentials
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
