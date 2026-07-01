# Quickstart: Standing Inventory Dashboard

## Running Tests
To run all tests (including backend inventory tests and the new LiveView test):
```bash
mix test
```

To run only the new web dashboard test:
```bash
mix test test/agent_os_web/inventory_live_test.exs
```

To run only the inventory unit tests:
```bash
mix test test/agent_os/inventory_test.exs
```

---

## Verifying Locally

1. Start the Phoenix application:
   ```bash
   mix phx.server
   ```
2. Navigate to: `http://localhost:4000/inventory`
3. Verify that all agents in `manifests/` (e.g. `manifests/discovery.md`) are listed.
4. Trigger or seed some states in `data/run_log.md` and check that the dashboard refreshes within 5 seconds.
