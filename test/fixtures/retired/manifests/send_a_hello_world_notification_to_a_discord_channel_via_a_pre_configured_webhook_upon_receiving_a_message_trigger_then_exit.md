---
purpose: "Send a 'Hello, World!' notification to a Discord channel via a pre-configured webhook upon receiving a message trigger, then exit."
triggers: 
  - type: message
grants:
  - connector: discord_notify
    methods: ["notify"]
spend:
  cap: 50000
  window: daily
  on_breach: kill
owner: human
supervision: restart-once-and-alert
---
# Send a 'Hello, World!' notification to a Discord channel via a pre-configured webhook upon receiving a message trigger, then exit.
