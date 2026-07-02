defmodule AgentOS.Fixtures.WorldB.Hostile do
  @moduledoc """
  Agent-agnostic worst-case hostile output fixtures for World-B verification.
  Used to simulate adversarial actions at enforcement chokepoints.
  """

  @doc """
  T003 (a): Mixed proposed action batch containing:
  - 1 valid/granted action: kv_append with append method
  - 1 ungranted action: unknown_connector
  - 1 malformed action: bad shape (no type)
  """
  def mixed_batch do
    [
      %{"type" => "kv_append", "method" => "append", "payload" => %{"name" => "hostile_payload"}},
      %{"type" => "unknown_connector"},
      %{"foo" => "bar"}
    ]
  end

  @doc """
  T003 (b): Granted action type but aimed out-of-scope for recipient.
  """
  def spoofed_recipient_action do
    %{"type" => "external_send", "recipient" => "malicious-inbox", "method" => "send"}
  end

  @doc """
  T003 (b): Granted action type but using out-of-scope method.
  """
  def spoofed_method_action do
    %{"type" => "kv_append", "method" => "delete"}
  end

  @doc """
  In-scope version of external_send.
  """
  def in_scope_external_send_action do
    %{"type" => "external_send", "recipient" => "owner-inbox", "method" => "send"}
  end

  @doc """
  T004: Trigger-shaped string for US5.
  """
  def trigger_string do
    "bookmark_saved"
  end

  @doc """
  T004: Attempts by the agent to approve its own held action (US6).
  Returns a list of raw proposed actions targeting approvals or approval resumes.
  """
  def agent_approval_attempts(ref) do
    [
      %{"type" => "approval", "decision" => "approve", "ref" => ref},
      %{"type" => "approval_resume", "ref" => ref},
      %{
        "type" => "external_send",
        "recipient" => "approval_intake",
        "method" => "approve",
        "payload" => %{"ref" => ref}
      }
    ]
  end

  @doc """
  T005: Probe an agent-bound payload for any manifest field (US7).
  Returns a list of found manifest keys.
  """
  def probe_payload_for_manifest(payload) do
    json = Jason.encode!(payload)

    keys = [
      "grants",
      "recipients",
      "methods",
      "cost",
      "requires_deploy_consent",
      "requires_runtime_approval",
      "spend",
      "cap",
      "window",
      "on_breach"
    ]

    Enum.filter(keys, fn key -> String.contains?(json, key) end)
  end

  @doc """
  T005: Probe an agent-bound payload or container argv for credentials (US8).
  Returns a list of found secret values.
  """
  def probe_for_credentials(subject, secrets) when is_list(subject) do
    Enum.flat_map(subject, fn item -> probe_for_credentials(item, secrets) end)
  end

  def probe_for_credentials(subject, secrets) when is_map(subject) do
    json = Jason.encode!(subject)
    Enum.filter(secrets, fn secret -> String.contains?(json, secret) end)
  end

  def probe_for_credentials(subject, secrets) when is_binary(subject) do
    Enum.filter(secrets, fn secret -> String.contains?(subject, secret) end)
  end

  def probe_for_credentials(_, _), do: []
end
