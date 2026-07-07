# Quickstart: Priorities Coach Live Smoke

To manually execute the Priorities Coach live smoke test after deployment:

1. **Wait or Trigger 0800 Schedule**: Let the 0800 time trigger fire, or manually invoke it.
2. **Observe Local Read**: Check that the coach reads the real local priorities document (via `file_read`).
3. **Observe Discord Notification**: Verify that the coach sends the check-in question to the configured Discord channel (via `discord_notify`).
4. **Reply via Discord**: Send a reply in the Discord channel.
5. **Observe Ingestion**: Watch the substrate console to confirm the Discord ingress receives the reply and submits it via `TriggerGateway`.
6. **Observe Write-Back**: Verify the coach writes the updated content back to the local priorities document (via `file_write`).
