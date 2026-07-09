---
purpose: "An agent that checks the local time on its server and sends it as French words to the user via Discord."
triggers: 
  - type: time
    at: "08:00"
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
# An agent that checks the local time on its server and sends it as French words to the user via Discord.
