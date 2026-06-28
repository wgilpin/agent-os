---
purpose: "Surface high-signal AI/ML content from the people-roster; read-and-digest only."
triggers:
  - type: time
    at: "07:00"
connectors:
  - record_signal
mounts:
  - roster_trust
outputs:
  - append_digest
spend:
  cap: 5
owner: human
supervision: restart-once-and-alert
---
# Discovery agent

One-line human description, kept in sync with config/config.exs by hand.
