# Research: Queryable State Store (Agent-Invisible Namespaces)

## 1. SQLite with JSON Support

To support domain-blind record storage, the SQLite tables are kept simple with a single JSON text column. Modern SQLite (and `exqlite`) supports `json_extract/2` for query filtering:

```sql
SELECT data FROM records WHERE json_extract(data, '$.price') >= ?
```

This allows indexing and filtering on arbitrary fields without modifying the database schema for each agent's specific domain model.

## 2. exqlite Package Integration

`exqlite` is a native Erlang NIF wrapper for SQLite3. It operates in-process:
- **Connection**: `{:ok, conn} = Exqlite.Sqlite3.open("data/store/namespace.db")`
- **In-Memory (for tests)**: `{:ok, conn} = Exqlite.Sqlite3.open(":memory:")` (conforms to Principle IV: no remote dependencies, no Docker).
- **Execution**:
  - `{:ok, statement} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO records (data) VALUES (?)")`
  - `:ok = Exqlite.Sqlite3.bind(conn, statement, [Jason.encode!(record_map)])`
  - `:done = Exqlite.Sqlite3.step(conn, statement)`

## 3. Namespace Invisibility Design

- **Logical Handles**: An agent proposes a write or query referring to a logical handle (alias) like `"feedback"` or `"history"`.
- **Substrate Mapping**: The manifest defines grants with logical handles mapped to real database namespaces:
```yaml
grants:
  - connector: store_append
    handle: "feedback"
    namespace: "prod_agent_feedback_v1"
```
- **Gate Evaluation**: `Gate.evaluate` matches the action (e.g. `store_append` to `"feedback"`), resolves the mapping, and populates `action.grant_resolved_namespace = "prod_agent_feedback_v1"`.
- **Effector execution**: The effector passes this namespace to the connector, which calls `StateStore.apply_action/2` with the real namespace name, maintaining perfect agent invisibility.
