# Data Model: Queryable State Store (Agent-Invisible Namespaces)

## 1. Database Schema (SQLite)

Every SQLite namespace file contains a single table:

```sql
CREATE TABLE IF NOT EXISTS records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  data TEXT NOT NULL,
  created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
```

- `data`: A TEXT column containing the JSON-encoded map representing the opaque record.

## 2. Struct Schema Updates

### ProposedAction

```elixir
defstruct [:type, :recipient, :method, :payload, :grant_resolved_namespace]
```

- `grant_resolved_namespace`: String. The real database namespace name resolved by the substrate Gate from the manifest grant.

### Manifest.Grant

```elixir
defstruct [:connector, :recipients, :methods, :namespace, :handle]
```

- `handle`: String. The logical handle (alias) used by the agent to refer to the store (e.g. `"feedback"`).
- `namespace`: String. The real namespace name resolved substrate-side.
