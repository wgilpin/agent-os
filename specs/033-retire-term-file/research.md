# Research: Retire Term-File State Store

## 1. SQLite Map Mode Table Design

To support the key-value map contract, each map-mode database file creates a `map_store` table:

```sql
CREATE TABLE IF NOT EXISTS map_store (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

Both keys and values are serialised: keys are stored as text (e.g., `"spend_ledger"` or `"approvals"`), and values are JSON-serialised representations of the terms.

## 2. UPSERT SQL Syntax

When `:put` is called to set a key to a value, we execute an `INSERT OR REPLACE` or `ON CONFLICT` UPSERT:

```sql
INSERT INTO map_store (key, value) VALUES (?, ?)
ON CONFLICT(key) DO UPDATE SET value=excluded.value;
```

This updates a single key without rewriting other keys in the database.

## 3. Nested Operations (:delete_in, :append)

For nested modifications (such as updating a sub-key or appending to a list at a key):
1. **Query**: Retrieve the current JSON string value for the top-level key:
   `SELECT value FROM map_store WHERE key = ?`
2. **Decode**: Decode the JSON string to an Elixir map.
3. **Mutate**: Apply the nested operation (e.g., `List.delete_at`, `List.insert_at`, or appending).
4. **Persist**: Write the updated map back via UPSERT.

This continues to run inside the GenServer process serialisation, guaranteeing atomic updates.

## 4. Deleting Term-File Code

- The functions/calls calling `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1` are removed.
- All file load/write operations inside `state_store.ex` that manage `.term` files are deleted.
- Mix and application supervisor configurations are updated to swap `.term` extensions with `.db`.
- The database is initialized and tables are prepared on start.
