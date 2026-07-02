defmodule AgentOS.CredentialSourceTest do
  use ExUnit.Case, async: false

  alias AgentOS.CredentialSource

  setup do
    # Capture original environment and config settings
    original_model_key = System.get_env("MODEL_KEY")
    original_outbound_token = System.get_env("OUTBOUND_TOKEN")
    original_search_key = System.get_env("SEARCH_API_KEY")
    original_config = Application.get_env(:agent_os, :credentials)

    # Clean the environment for test executions
    System.delete_env("MODEL_KEY")
    System.delete_env("OUTBOUND_TOKEN")
    System.delete_env("SEARCH_API_KEY")
    Application.delete_env(:agent_os, :credentials)

    # Backup existing .env file if present in workspace root
    has_env_file = File.exists?(".env")

    if has_env_file do
      File.cp!(".env", ".env.backup")
      File.rm!(".env")
    end

    on_exit(fn ->
      # Restore original environment settings
      if original_model_key,
        do: System.put_env("MODEL_KEY", original_model_key),
        else: System.delete_env("MODEL_KEY")

      if original_outbound_token,
        do: System.put_env("OUTBOUND_TOKEN", original_outbound_token),
        else: System.delete_env("OUTBOUND_TOKEN")

      if original_search_key,
        do: System.put_env("SEARCH_API_KEY", original_search_key),
        else: System.delete_env("SEARCH_API_KEY")

      if original_config,
        do: Application.put_env(:agent_os, :credentials, original_config),
        else: Application.delete_env(:agent_os, :credentials)

      # Restore original .env file
      if has_env_file do
        File.cp!(".env.backup", ".env")
        File.rm!(".env.backup")
      else
        File.rm(".env")
      end
    end)

    :ok
  end

  test "resolves credentials directly from System environment" do
    System.put_env("MODEL_KEY", "env_model_key_value")
    System.put_env("OUTBOUND_TOKEN", "env_outbound_token_value")

    resolved = CredentialSource.resolve_credentials()

    assert resolved == %{
             model_key: "env_model_key_value",
             outbound_token: "env_outbound_token_value"
           }
  end

  test "resolves credentials from .env file" do
    # Write a temporary .env file
    File.write!(".env", """
    # This is a comment
    MODEL_KEY=file_model_key_value
    export OUTBOUND_TOKEN="file_outbound_token_value"
    """)

    # Enable autostart temporarily so the resolver loads the file
    Application.put_env(:agent_os, :autostart, true)

    resolved = CredentialSource.resolve_credentials()

    # Restore autostart
    Application.put_env(:agent_os, :autostart, false)

    assert resolved == %{
             model_key: "file_model_key_value",
             outbound_token: "file_outbound_token_value"
           }

    # Verify they were also put in System environment
    assert System.get_env("MODEL_KEY") == "file_model_key_value"
    assert System.get_env("OUTBOUND_TOKEN") == "file_outbound_token_value"
  end

  test "falls back to Application config settings when env variables are not present" do
    Application.put_env(:agent_os, :credentials, %{
      model_key: "config_model_key",
      outbound_token: "config_outbound_token"
    })

    resolved = CredentialSource.resolve_credentials()

    assert resolved == %{
             model_key: "config_model_key",
             outbound_token: "config_outbound_token"
           }
  end

  test "filters out missing, empty, or whitespace-only keys" do
    # Set whitespace-only values in environment
    System.put_env("MODEL_KEY", "   ")
    System.put_env("OUTBOUND_TOKEN", "")

    resolved = CredentialSource.resolve_credentials()

    # The resulting credentials map should be completely empty
    assert resolved == %{}
  end

  test "System environment takes precedence over Application config settings" do
    System.put_env("MODEL_KEY", "system_precedence_key")

    Application.put_env(:agent_os, :credentials, %{
      model_key: "config_fallback_key",
      outbound_token: "config_token"
    })

    resolved = CredentialSource.resolve_credentials()

    assert resolved == %{
             model_key: "system_precedence_key",
             outbound_token: "config_token"
           }
  end
end
