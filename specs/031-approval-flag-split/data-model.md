# Data Model: Approval Flag Split

## 1. Schema Modifications

The metadata structure of the connector capability is modified as follows:

### Connector Metadata

```diff
  @type capability :: %{
          name: String.t(),
          mutating?: boolean(),
-         requires_approval?: boolean(),
+         requires_deploy_consent?: boolean(),
+         requires_runtime_approval?: boolean(),
          credential: atom() | nil,
          cost: integer()
        }
```

- `requires_deploy_consent?`: Boolean. Determines if build-time human approval is required prior to agent deployment.
- `requires_runtime_approval?`: Boolean. Determines if runtime per-call human approval is required prior to effector execution.

## 2. Connector Mappings

All existing connectors are mapped to the new schema:

| Connector | mutating? | requires_deploy_consent? | requires_runtime_approval? | credential | cost |
|---|---|---|---|---|---|
| `gmail_read` | `false` | `false` | `false` | `nil` | `0` |
| `gmail_draft` | `true` | `false` | `false` | `nil` | `0` |
| `kv_append` | `true` | `false` | `false` | `nil` | `0` |
| `external_send` | `true` | `true` | `true` | `:outbound_token` | `2000` |
