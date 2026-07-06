# Quickstart: File Connectors

1. Configure a grant in the manifest to map a handle to a file path:

```elixir
%AgentOS.Manifest.Grant{
  connector: "file_read",
  handle: "priorities",
  path: "/path/to/priorities.md"
}
```

2. The agent proposes a file read action via its handle:

```json
{
  "type": "file_read",
  "payload": {
    "handle": "priorities"
  }
}
```

3. For writes, ensure a `file_write` grant exists, and the agent proposes:

```json
{
  "type": "file_write",
  "payload": {
    "handle": "priorities",
    "content": "Updated contents..."
  }
}
```
