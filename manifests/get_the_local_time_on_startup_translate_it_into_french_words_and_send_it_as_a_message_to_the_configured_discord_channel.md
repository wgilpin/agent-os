---
purpose: "Get the local time on startup, translate it into French words, and send it as a message to the configured Discord channel."
triggers: 
  - type: startup
grants:
  - connector: discord_notify
    methods: ["notify"]
spend:
  cap: 100000
  window: daily
  on_breach: kill
owner: human
supervision: restart-once-and-alert
---
# Get the local time on startup, translate it into French words, and send it as a message to the configured Discord channel.
