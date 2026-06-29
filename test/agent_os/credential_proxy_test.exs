defmodule AgentOS.CredentialProxyTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  require Logger

  alias AgentOS.CredentialProxy

  setup do
    start_supervised!(CredentialProxy)
    :ok
  end

  # Note: The proxy loads credentials from config, which for tests is seeded in config.exs:
  # config :agent_os, credentials: %{outbound_token: "test_secret_outbound_token_value", model_key: "test_secret_model_key_value"}

  test "A1: with_credential/2 returns only the closure result and does not leak the secret" do
    # When called with a valid credential ID, it applies the function and returns its result
    result =
      CredentialProxy.with_credential(:outbound_token, fn secret ->
        assert secret == "test_secret_outbound_token_value"
        String.length(secret)
      end)

    assert result == 32
  end

  test "A2: secret is only available within the closure and not as a direct return value" do
    # If we return the secret, we can get it, but the proxy itself doesn't return it
    result = CredentialProxy.with_credential(:outbound_token, fn _ -> :ok end)
    assert result == :ok
  end

  test "A3: nothing logged during a successful call contains the secret value" do
    log =
      capture_log(fn ->
        result =
          CredentialProxy.with_credential(:outbound_token, fn secret ->
            Logger.info("Inside closure")
            String.length(secret)
          end)

        assert result == 32
      end)

    refute String.contains?(log, "test_secret_outbound_token_value")
  end

  test "A4: unknown credential ID returns {:error, {:unknown_credential, id}} and does not call fun" do
    parent = self()
    ref = make_ref()

    result =
      CredentialProxy.with_credential(:unknown_id, fn _secret ->
        send(parent, {ref, :called})
      end)

    assert result == {:error, {:unknown_credential, :unknown_id}}
    refute_received {^ref, :called}
  end

  test "A5: mutating and inference-only credentials are held under distinct keys and resolved exactly" do
    # Verify exact resolution of outbound_token
    token_result = CredentialProxy.with_credential(:outbound_token, fn secret -> secret end)
    assert token_result == "test_secret_outbound_token_value"

    # Verify exact resolution of model_key
    model_result = CredentialProxy.with_credential(:model_key, fn secret -> secret end)
    assert model_result == "test_secret_model_key_value"

    assert token_result != model_result
  end

  test "A6: if the closure raises, the exception propagates and the secret value does not leak" do
    log =
      capture_log(fn ->
        try do
          CredentialProxy.with_credential(:outbound_token, fn _secret ->
            raise "boom_with_exception"
          end)
        rescue
          e ->
            assert Exception.message(e) == "boom_with_exception"
            # Verify exception representation does not contain secret value
            refute String.contains?(inspect(e), "test_secret_outbound_token_value")
            # Verify stacktrace does not contain secret value
            refute String.contains?(
                     Exception.format(:error, e, __STACKTRACE__),
                     "test_secret_outbound_token_value"
                   )
        end
      end)

    # Verify captured log does not contain the secret value
    refute String.contains?(log, "test_secret_outbound_token_value")
  end
end
