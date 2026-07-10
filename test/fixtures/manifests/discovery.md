---
purpose: "Surface high-signal AI/ML content from the people-roster; read-and-digest only."
triggers:
  - type: time
    at: "07:00"
  - type: message
  - type: event
    name: bookmark_saved
grants:
  - connector: kv_append
    methods: [append]
  - connector: external_send
    recipients: ["owner-inbox"]
    methods: [send]
mounts:
  - roster_trust
spend:
  cap: 500000
  window: daily
  on_breach: kill
owner: human
supervision: restart-once-and-alert
---
# Discovery agent

One-line human description, kept in sync with config/config.exs by hand.
