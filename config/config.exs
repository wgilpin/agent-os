import Config

# Hard-wired v0 provisioning surface. At v0 the substrate is configured by hand and the
# manifest is kept in sync manually; later phases provision from the manifest itself.
config :agent_os,
  manifest_path: "manifests/discovery.md",
  roster_path: "data/roster.term",
  bookmarks_path: "data/bookmarks.json",
  autostart: true

# Hard-wired agent configuration (manifest path, command, timezone, schedule, and capabilities)
config :agent_os, :agent,
  manifest_path: "manifests/discovery.md",
  agent_cmd: "docker",
  agent_args: [],
  tz: "Etc/UTC",
  run_hour: 7,
  connectors: ["record_signal"],
  outputs: ["append_digest"],
  spend_cap: 5

# In tests, the supervision tree does not auto-start the singleton state process — each
# test starts its own StateStore against an isolated temp term-file (never live state).
if config_env() == :test do
  config :agent_os,
    autostart: false,
    bookmarks_path: "test/fixtures/hostile_bookmarks.json"
end
