---
purpose: "When the agent starts, get the local time on the agent's server, then send a message to the harness-configured discord channel with the time expressed in French words."
triggers: []
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
# When the agent starts, get the local time on the agent's server, then send a message to the harness-configured discord channel with the time expressed in French words.
