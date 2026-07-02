# Quickstart: Retire Term-File State Store

This guide explains how to verify the new SQLite-backed map storage engine.

## 1. Verifying Table Schemas

Once the system boots, verify that the SQLite database files are created under `data/`:

```bash
# Check if database files exist instead of term files
ls data/*.db
```

Open a database file and check its schema:

```bash
sqlite3 data/spend_ledger.db ".schema"
```

Expected output:
```sql
CREATE TABLE map_store (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

## 2. Running Verification Tests

To verify that the map contract performs identically to the legacy term-file implementation, and that all system mounts are successfully integrated:

```bash
# Run state store tests
mix test test/agent_os/state_store_test.exs

# Run the complete test battery (ensuring world-B is green)
mix test
```
