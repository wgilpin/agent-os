# Data Model: Retire Term-File State Store

## 1. Database Schema (Map Mode)

For map-backed mounts, the SQLite database creates the following table:

```sql
CREATE TABLE IF NOT EXISTS map_store (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

- `key`: TEXT column representing the top-level map key (e.g. `"test_agent"`).
- `value`: TEXT column representing the JSON-encoded Elixir value (e.g., `{"spent": 500, "window_start": "..."}`).

## 2. StateStore Options

The `StateStore` process options are extended to support the operational mode:

```elixir
Keyword.put_new(opts, :mode, :map)
```

- `:mode` - Either `:map` (default, manages `map_store` table) or `:record` (manages `records` table from 09-02).
- `:path` - Binary path pointing to the `.db` SQLite database file (e.g., `data/roster.db`).
