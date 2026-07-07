import Config

# Hard-wired v0 provisioning surface. At v0 the substrate is configured by hand and the
# manifest is kept in sync manually; later phases provision from the manifest itself.
# Secrets/tokens for capabilities are sourced from OS env, never committed directly.
config :agent_os,
  manifest_path: "manifests/discovery.md",
  roster_path: "data/roster.db",
  spend_ledger_path: "data/spend_ledger.db",
  pending_approvals_path: "data/pending_approvals.db",
  admitted_plugins_path: "data/admitted_plugins.db",
  bookmarks_path: "data/bookmarks.json",
  conformance_path: "data/conformance.db",
  provenance_path: "data/provenance.db",
  judge_results_path: "data/judge_results.db",
  pipeline_runs_path: "data/pipeline_runs.db",
  security_review_results_path: "data/security_review_results.db",
  admin_alerts_path: "data/admin_alerts.md",
  audit_run_hour: 8,
  conformance_window: 20,
  conformance_quiet_streak: 3,
  conformance_denied_threshold: 3,
  spend_defaults: %{window: :daily, on_breach: :kill},
  elicitor_spend_cap: 10_000_000,
  agent_codegen_model: "google/gemini-3.5-flash",
  agent_runtime_model: "google/gemini-3-flash-preview",
  judge_model: "google/gemini-3.5-flash",
  autostart: true,
  credentials: %{},
  inference_prices: %{}

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

# Phoenix/LiveView web interface configuration
config :agent_os, AgentOSWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  secret_key_base: "super_secret_key_base_that_is_at_least_64_characters_long_1234567890abcdef",
  pubsub_server: AgentOS.PubSub,
  live_view: [signing_salt: "g4x1p45OaYx6d/g3m7c8d9e/A1B2C3D4E5F6G7H8I9J0="],
  render_errors: [
    formats: [html: AgentOSWeb.ErrorHTML],
    layout: false
  ]

config :phoenix, :json_library, Jason

# In tests, the supervision tree does not auto-start the singleton state process — each
# test starts its own StateStore against an isolated temp term-file (never live state).
if config_env() == :test do
  config :agent_os,
    autostart: false,
    review_mode: :dangerously_skip_review,
    bookmarks_path: "test/fixtures/hostile_bookmarks.json",
    credentials: %{
      outbound_token: "test_secret_outbound_token_value",
      model_key: "test_secret_model_key_value",
      search_api_key: "test_search_api_key_value"
    },
    inference_prices: %{
      "mock-model" => %{input: 10_000_000, output: 30_000_000},
      "google/gemini-2.5-flash" => %{input: 10_000_000, output: 30_000_000},
      "google/gemini-3-flash-preview" => %{input: 10_000_000, output: 30_000_000}
    }

  config :agent_os, AgentOSWeb.Endpoint,
    server: false,
    http: [ip: {127, 0, 0, 1}, port: 4002]
end
