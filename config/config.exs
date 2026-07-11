import Config

# Substrate configuration. The agent inventory is manifest-driven: the kernel enumerates
# manifests/*.md rather than reading a hard-wired agent name from config. There is no
# global `:manifest_path` and no `:agent` block in prod/dev — the app boots with zero
# configured agents. The hard-wired "discovery" agent survives only as a test fixture
# (see the `config_env() == :test` block below).
# Secrets/tokens for capabilities are sourced from OS env, never committed directly.
config :agent_os,
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
  # Container runtime images. Both config and generated agents run through the one
  # Sandbox.build_argv path (FR-004), differing only in image + mounts: the config agent's
  # image bakes its own code, while the generated-agent image bakes deps only and mounts the
  # body read-only at run time (FR-002/FR-003).
  agent_image: "agent-discovery:dev",
  generated_agent_image: "agent-generated:dev",
  # Inference socket topology (feature 045). `:inference_socket_volume` selects the mode:
  #   nil            -> host-bind mode: the socket is a host file bind-mounted into the agent
  #                     at /tmp/inference.sock (current behaviour; unchanged when unset).
  #   "<volume>"     -> shared-volume mode: the socket lives on the named Docker volume
  #                     mounted at `:inference_socket_volume_path` in BOTH the substrate
  #                     container and every agent container (identical path, no translation).
  # macOS/OrbStack needs shared-volume mode because a Unix socket is kernel-local: a host-bind
  # socket file node is shared across the VM boundary but not its listening endpoint, so an
  # agent in the VM gets ECONNREFUSED against a broker on the macOS host kernel.
  inference_socket_volume: nil,
  inference_socket_volume_path: "/run/aos",
  # Substrate-owned agents: hidden from the inventory UI and refused by every
  # AgentLifecycle mutation (they are managed by config/code, not the dashboard).
  system_agents: ["discovery"],
  autostart: true,
  load_dotenv: true,
  credentials: %{},
  inference_prices: %{}

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

# Dev-only code reloading: a browser refresh recompiles changed Elixir modules
# (LiveView websocket events don't; see endpoint.ex). Never enabled in test/prod.
if config_env() == :dev do
  config :agent_os, AgentOSWeb.Endpoint, code_reloader: true
end

# In tests, the supervision tree does not auto-start the singleton state process — each
# test starts its own StateStore against an isolated temp term-file (never live state).
if config_env() == :test do
  # The "discovery" agent is a test-only fixture. The suites (run_supervisor, port_runner,
  # deterministic_e2e, world_b, scheduler, provisioner) exercise the port boundary and the
  # legacy hard-wired provisioning surface against test/fixtures/manifests/discovery.md,
  # so the `:agent` block and the global `:manifest_path` default live here — never in prod/dev.
  config :agent_os, :agent,
    manifest_path: "test/fixtures/manifests/discovery.md",
    agent_cmd: "docker",
    agent_args: [],
    tz: "Etc/UTC",
    run_hour: 7,
    grants: [
      %{connector: "kv_append", recipients: nil, methods: ["append"]},
      %{connector: "external_send", recipients: ["owner-inbox"], methods: ["send"]}
    ],
    spend: %{cap: 500_000, window: :daily, on_breach: :kill}

  config :agent_os,
    manifest_path: "test/fixtures/manifests/discovery.md",
    autostart: false,
    # Legacy tests use the discovery manifest as their render/inventory fixture;
    # tests exercising the system-agent guard override this per-test.
    system_agents: [],
    # Tests must never append to the live data/run_log.md (test_helper.exs wipes
    # this file at suite start).
    run_log_path: Path.join(System.tmp_dir!(), "agent_os_test_run_log.md"),
    # Never load real secrets from .env into the test VM (Constitution IV): tests
    # that flip :autostart (e.g. the UDS broker harness) must not pull the live
    # webhook/model keys into System env for the rest of the suite.
    load_dotenv: false,
    review_mode: :dangerously_skip_review,
    bookmarks_path: "test/fixtures/hostile_bookmarks.json",
    credentials: %{
      outbound_token: "test_secret_outbound_token_value",
      model_key: "test_secret_model_key_value",
      search_api_key: "test_search_api_key_value",
      # Fake webhook so tests never depend on a developer shell exporting the real
      # DISCORD_WEBHOOK_URL (System env still takes precedence in the resolver; the
      # suite-wide transport stub in test_helper.exs is the hard guard).
      discord_webhook_url: "https://discord.invalid/webhook-test"
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

# Container-mode overrides (feature 045). The compose services export AOS_IN_CONTAINER=1. Config
# is evaluated at compile time INSIDE the container (the repo is bind-mounted and compiled in-VM
# on each `mix` invocation), so AOS_IN_CONTAINER is set when these are read — for the full dev app
# (`mix run --no-halt`) and the docker E2E suite (`mix test --only docker`) alike.
if System.get_env("AOS_IN_CONTAINER") not in [nil, ""] do
  # Shared-volume socket topology is the ONLY way a running substrate reaches its agents in-VM: a
  # host-bind socket is kernel-local and dead across the OrbStack boundary. Select it in EVERY env
  # when in-container so the full dev substrate (FR-013) and the docker E2E suite agree. Both
  # host-process bodies (PortRunner, same kernel) and dispatched SIBLING agent containers reach the
  # broker socket on the shared aos_inf volume at the identical path. Unset on the host, so the
  # default host suite stays in host-bind mode (SC-004). Unit tests that assert host-bind behaviour
  # force :host_bind explicitly in their own setup, so this default is safe for them too.
  config :agent_os,
    inference_socket_volume: "aos_inf",
    inference_socket_volume_path: "/run/aos",
    inference_uds_path: "/run/aos/inference.sock"

  # Expose the LiveView web UI to the macOS host browser (FR-012/SC-006). On the host the endpoint
  # binds loopback; in the container it must bind all interfaces so the published 4000:4000 port
  # forwards from the host. Skipped in :test (the endpoint server is disabled there — nothing binds).
  if config_env() != :test do
    config :agent_os, AgentOSWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: 4000]
  end
end
