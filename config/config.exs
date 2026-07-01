import Config

# Hard-wired v0 provisioning surface. At v0 the substrate is configured by hand and the
# manifest is kept in sync manually; later phases provision from the manifest itself.
# Secrets/tokens for capabilities are sourced from OS env, never committed directly.
config :agent_os,
  manifest_path: "manifests/discovery.md",
  roster_path: "data/roster.term",
  spend_ledger_path: "data/spend_ledger.term",
  pending_approvals_path: "data/pending_approvals.term",
  bookmarks_path: "data/bookmarks.json",
  conformance_path: "data/conformance.term",
  provenance_path: "data/provenance.term",
  judge_results_path: "data/judge_results.term",
  admin_alerts_path: "data/admin_alerts.md",
  audit_run_hour: 8,
  conformance_window: 20,
  conformance_quiet_streak: 3,
  conformance_denied_threshold: 3,
  spend_defaults: %{window: :daily, on_breach: :kill},
  elicitor_spend_cap: 10_000_000,
  autostart: true,
  credentials: %{
    outbound_token: System.get_env("OUTBOUND_TOKEN"),
    model_key: System.get_env("MODEL_KEY")
  },
  # Prod placeholder for the real Gemini 3-series model in micro-dollars
  inference_prices:
    %{
      # "gemini-3-flash" => %{input: 75, output: 250}
      "google/gemini-2.5-flash" => %{input: 75, output: 250}
    }

# Hard-wired agent configuration (manifest path, command, timezone, schedule, and capabilities)
config :agent_os, :agent,
  manifest_path: "manifests/discovery.md",
  agent_cmd: "docker",
  agent_args: [],
  tz: "Etc/UTC",
  run_hour: 7,
  grants: [
    %{connector: "kv_append", recipients: nil, methods: ["append"]},
    %{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}
  ],
  spend: %{cap: 500_000, window: :daily, on_breach: :kill}

# In tests, the supervision tree does not auto-start the singleton state process — each
# test starts its own StateStore against an isolated temp term-file (never live state).
if config_env() == :test do
  config :agent_os,
    autostart: false,
    review_mode: :dangerously_skip_review,
    bookmarks_path: "test/fixtures/hostile_bookmarks.json",
    credentials: %{
      outbound_token: "test_secret_outbound_token_value",
      model_key: "test_secret_model_key_value"
    },
    inference_prices: %{
      "mock-model" => %{input: 10, output: 30},
      "google/gemini-2.5-flash" => %{input: 10, output: 30}
    }
end
